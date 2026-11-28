extends SceneTree

# Requires a windowed renderer for framebuffer readback. Pass -- --capture-dir=<directory>
# to also save the fixed camera captures.
const SOURCE := "res://shaders/weather_overlay.gdshader"
const NOISE := "res://assets/textures/weather/valley_fog_noise.png"
const SIZE := Vector2i(240, 128)
const GRID := Vector2i(6, 4)
const TILE_COLUMNS := 3
const HEX_RADIUS := 40.0 / sqrt(3.0)
const SAMPLE_Y := 69
const LAND := 2.0 / 255.0
const FOG_TOP := 0.30

var _viewport: SubViewport
var _camera: Camera2D
var _subject: ColorRect
var _capture_dir := ""
var _failures := 0
var _benchmark := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not root.is_node_ready():
		await root.ready
	if DisplayServer.get_name() == "headless":
		push_error("valley_fog_render_test requires a windowed renderer")
		quit(1)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
		if argument == "--benchmark":
			_benchmark = true
	if not _capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_capture_dir))
	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_camera = Camera2D.new()
	_camera.position = Vector2(SIZE) * 0.5
	_viewport.add_child(_camera)
	_subject = ColorRect.new()
	_subject.size = Vector2(SIZE)
	_viewport.add_child(_subject)
	var terrain := _mountain_raster()
	var field := _fog_image(Color(1.0, FOG_TOP, 0.0))
	var baseline: Image
	for use_field in [true, false]:
		for tiled in [false, true]:
			var variant := ("field" if use_field else "indexed") + ("_tiled" if tiled else "_regular")
			var mat := _material(use_field, tiled, terrain)
			_set_fog(mat, field, field)
			var fog := await _capture(variant)
			_check_cutout(fog, variant)
			if baseline == null:
				baseline = fog
			else:
				_expect(_max_alpha_delta(baseline, fog) <= 2.0 / 255.0,
					"%s matches the regular cell-field ground contour" % variant)
			await _check_visibility(mat, field, variant)
			if use_field and not tiled:
				await _check_tuning(mat, field, fog)
				await _check_time_and_wrap(mat, field, fog)
				await _check_cloud_composition(mat, field)
	if _benchmark:
		await _measure_gpu(terrain, field)
	print("[valley-fog-render] failures=", _failures)
	_viewport.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)


func _material(use_field: bool, tiled: bool, terrain: Image, valley_fog: bool = true) -> ShaderMaterial:
	var prefix := "#define PK_WEATHER_HIGH\n"
	if valley_fog:
		prefix += "#define PK_VALLEY_FOG\n"
	if use_field:
		prefix += "#define PK_CELL_FIELD\n"
	if tiled:
		prefix += "#define MAP_VISUAL_TILED\n"
	var shader := Shader.new()
	shader.code = prefix + FileAccess.get_file_as_string(SOURCE)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_subject.material = mat
	mat.set_shader_parameter("world_size", Vector2(SIZE))
	mat.set_shader_parameter("wrap_period_x", float(SIZE.x))
	mat.set_shader_parameter("hex_size", HEX_RADIUS)
	mat.set_shader_parameter("map_dims", Vector2(GRID))
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("valley_fog_active", true)
	mat.set_shader_parameter("valley_fog_sea_level", 0.10)
	mat.set_shader_parameter("valley_fog_cur_layer", 0)
	mat.set_shader_parameter("valley_fog_prev_layer", 1)
	mat.set_shader_parameter("valley_fog_detail", 0)
	mat.set_shader_parameter("weather_warp_amp", 0.0)
	_set_visibility(mat, -1)
	var empty_weather := _image(GRID, Color(0, 0, 0, 0))
	if use_field:
		_set_clouds(mat, 0.0)
		mat.set_shader_parameter("weather_table_bound", true)
		mat.set_shader_parameter("weather_table_size", Vector2(GRID))
	else:
		var flat_index := _image(Vector2i.ONE, Color(LAND, 0, 0, 1))
		mat.set_shader_parameter("lut_dims", Vector2(GRID))
		mat.set_shader_parameter("weather_lut", ImageTexture.create_from_image(empty_weather))
		mat.set_shader_parameter("weather_lut_prev", ImageTexture.create_from_image(empty_weather))
		mat.set_shader_parameter("visual_map_index_tiles" if tiled else "map_index_atlas",
			_layers([flat_index, flat_index, flat_index]) if tiled else ImageTexture.create_from_image(flat_index))
	if tiled:
		var interior := Vector2(float(SIZE.x) / TILE_COLUMNS, SIZE.y)
		mat.set_shader_parameter("visual_domain_size", Vector2(SIZE))
		mat.set_shader_parameter("visual_grid_size", Vector2(TILE_COLUMNS, 1))
		mat.set_shader_parameter("visual_interior_size", interior)
		mat.set_shader_parameter("visual_layer_size", interior + Vector2(4, 4))
		mat.set_shader_parameter("visual_logical_resolution", Vector2(SIZE))
		mat.set_shader_parameter("visual_gutter_px", 2.0)
		mat.set_shader_parameter("visual_height_tiles", _split_height(terrain))
	else:
		mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(terrain))
	return mat


func _set_clouds(mat: ShaderMaterial, coverage: float, wind_strength: float = 0.40) -> void:
	var weather := _image(GRID, Color(0, 0, coverage, 0))
	var wind_color := Color(1, 0.5, wind_strength, 1) if wind_strength > 0.0 else Color(0.5, 0.5, 0.0, 1)
	var wind := _image(GRID, wind_color)
	mat.set_shader_parameter("weather_table", _layers([weather, weather, wind, wind]))


func _set_visibility(mat: ShaderMaterial, hidden_col: int, lake_col: int = -1) -> void:
	var terrain_class := _image(GRID, Color(LAND, 0, 0, 1))
	terrain_class.fill_rect(Rect2i(0, 0, 1, GRID.y), Color.BLACK)
	var visibility := _image(GRID, Color(1, 0, 1, 1))
	if hidden_col >= 0:
		for row in GRID.y:
			visibility.set_pixel(hidden_col, row, Color(0.75, 0, 0, 1))
	if lake_col >= 0:
		for row in GRID.y:
			terrain_class.set_pixel(lake_col, row, Color(18.0 / 255.0, 0, 0, 1))
	mat.set_shader_parameter("cell_table", _layers([terrain_class, terrain_class, visibility, terrain_class]))
	mat.set_shader_parameter("cell_table_size", Vector2(GRID))
	mat.set_shader_parameter("cell_table_bound", true)
	mat.set_shader_parameter("valley_fog_visibility_required", hidden_col >= 0)


func _set_fog(mat: ShaderMaterial, current: Image, previous: Image) -> void:
	mat.set_shader_parameter("valley_fog_table", _layers([current, previous]))


func _check_cutout(fog: Image, variant: String) -> void:
	var west := fog.get_pixel(72, SAMPLE_Y).a
	var ridge := fog.get_pixel(120, SAMPLE_Y).a
	var east := fog.get_pixel(172, SAMPLE_Y).a
	var slope := fog.get_pixel(96, SAMPLE_Y).a
	var sea := fog.get_pixel(12, SAMPLE_Y).a
	_expect(west > 0.08 and east > 0.08 and ridge < 0.01 and sea < 0.01,
		"%s clear sky still shows fog in both valleys and clears the ridge and sea (%.3f, %.3f, %.3f, %.3f)"
			% [variant, west, east, ridge, sea])
	_expect(fog.get_pixel(26, SAMPLE_Y).a > 0.08,
		"%s keeps fog over below-sea-level terrain classified as land" % variant)
	_expect(slope > ridge + 0.01 and slope < west - 0.01,
		"%s fog thins continuously up the slope (%.3f)" % [variant, slope])


func _check_visibility(mat: ShaderMaterial, field: Image, variant: String) -> void:
	_set_visibility(mat, 2)
	var hidden_wet := await _capture(variant + "_hidden_wet")
	var hidden_dry := field.duplicate()
	for row in GRID.y:
		hidden_dry.set_pixel(2, row, Color(0, 0.95, 0))
	_set_fog(mat, hidden_dry, hidden_dry)
	var hidden_changed := await _capture(variant + "_hidden_dry")
	_expect(_max_alpha_delta(hidden_wet, hidden_changed) <= 1.0 / 255.0,
		"%s neither density nor fog top leak from hidden cells into visible neighbours" % variant)
	_expect(hidden_wet.get_pixel(80, SAMPLE_Y).a < 0.01 and hidden_wet.get_pixel(160, SAMPLE_Y).a > 0.08,
		"%s exact cell visibility masks hidden fog and retains visible fog" % variant)
	mat.set_shader_parameter("cell_table_bound", false)
	var missing_mask := await _capture(variant + "_missing_visibility")
	_expect(_alpha_sum(missing_mask) < 0.01, "%s fails closed when required visibility is missing" % variant)
	_set_fog(mat, field, field)
	_set_visibility(mat, -1, 4)
	var lake := await _capture(variant + "_lake")
	_expect(lake.get_pixel(160, SAMPLE_Y).a < 0.01 and lake.get_pixel(72, SAMPLE_Y).a > 0.08,
		"%s excludes an elevated lake using the cell's water class" % variant)
	_set_visibility(mat, -1)


func _check_time_and_wrap(mat: ShaderMaterial, field: Image, wet: Image) -> void:
	_set_fog(mat, _fog_image(Color(0.0, FOG_TOP, 0.0)), field)
	mat.set_shader_parameter("weather_lerp", 0.5)
	var transition := await _capture("transition")
	mat.set_shader_parameter("weather_lerp", 1.0)
	var dry := await _capture("dry")
	var middle := transition.get_pixel(72, SAMPLE_Y).a
	_expect(dry.get_pixel(72, SAMPLE_Y).a < 0.01 and middle > 0.02 and middle < wet.get_pixel(72, SAMPLE_Y).a,
		"fog interpolates from the still-contributing previous weather layer to a dry current frame")
	_set_fog(mat, field, field)
	mat.set_shader_parameter("valley_fog_detail", 2)
	var noise := load(NOISE) as Texture2D
	_expect(noise != null and noise.get_image().has_mipmaps(), "production noise is bound with mipmaps")
	mat.set_shader_parameter("valley_fog_noise", noise)
	_set_clouds(mat, 0.0, 1.0)
	mat.set_shader_parameter("world_time", 2.0)
	var detail := await _capture("flow_and_light")
	mat.set_shader_parameter("world_time", 9.0)
	var moved := await _capture("flow_moved")
	var wind_delta := _max_alpha_delta(detail, moved)
	_expect(wind_delta > 0.5 / 255.0, "local wind moves the detailed fog surface (alpha delta %.4f)" % wind_delta)
	_set_clouds(mat, 0.0, 0.0)
	var calm := await _capture("calm")
	mat.set_shader_parameter("world_time", 2.0)
	var calm_next := await _capture("calm_later")
	_expect(_max_alpha_delta(calm, calm_next) < 0.5 / 255.0, "calm weather keeps the fog pattern fixed")
	_set_clouds(mat, 0.0, 1.0)
	mat.set_shader_parameter("world_time", 2.0)
	_subject.position.x += SIZE.x
	_camera.position.x += SIZE.x
	_camera.force_update_scroll()
	var wrapped := await _capture("wrap_copy")
	_expect(_max_alpha_delta(detail, wrapped) <= 2.0 / 255.0,
		"animated fog repeats with the map when the camera crosses the wrap")
	_subject.position.x = 0.0
	_camera.position.x = SIZE.x * 0.5
	_camera.force_update_scroll()
	mat.set_shader_parameter("day_night_enabled", true)
	mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	mat.set_shader_parameter("tod_debug_sun_uv", Vector2(0.30, 0.50))
	var day := await _capture("valley_day")
	mat.set_shader_parameter("tod_debug_sun_uv", Vector2(0.80, 0.50))
	var night := await _capture("valley_night")
	var daylight_sample := day.get_pixel(72, SAMPLE_Y)
	var night_sample := night.get_pixel(72, SAMPLE_Y)
	_expect(daylight_sample.r > night_sample.r + 0.08 and absf(daylight_sample.a - night_sample.a) < 0.01,
		"night dims the local fog color while preserving its optical thickness")
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("tod_debug_sun_position_enabled", false)
	mat.set_shader_parameter("valley_fog_active", false)
	var disabled := await _capture("disabled")
	_expect(_max_alpha_delta(dry, disabled) <= 1.0 / 255.0,
		"shader bypass and zero density both leave the same clear weather")


func _check_tuning(mat: ShaderMaterial, field: Image, baseline: Image) -> void:
	_set_fog(mat, field, field)
	mat.set_shader_parameter("valley_fog_opacity", 0.0)
	var transparent := await _capture("tuning_zero_opacity")
	_expect(_alpha_sum(transparent) < 1.0, "editing fog opacity immediately clears the fog")
	mat.set_shader_parameter("valley_fog_opacity", 0.78)
	mat.set_shader_parameter("valley_fog_top_offset", 0.04)
	var raised := await _capture("tuning_raised_top")
	_expect(raised.get_pixel(96, SAMPLE_Y).a > baseline.get_pixel(96, SAMPLE_Y).a + 0.1,
		"raising the fog top immediately increases opacity on the slope")
	mat.set_shader_parameter("valley_fog_top_offset", 0.0)


func _check_cloud_composition(mat: ShaderMaterial, field: Image) -> void:
	_set_clouds(mat, 0.92)
	var clouds := await _capture("clouds_only")
	_set_fog(mat, field, field)
	mat.set_shader_parameter("valley_fog_active", true)
	var composite := await _capture("clouds_and_fog")
	_expect(_max_alpha_delta(clouds, composite) > 0.08 and _alpha_sum(clouds) > 100.0,
		"clouds and valley fog both contribute to a single composite")
	_expect(absf(composite.get_pixel(120, SAMPLE_Y).a - clouds.get_pixel(120, SAMPLE_Y).a) < 0.01,
		"the uncovered ridge retains its cloud coverage")


func _measure_gpu(terrain: Image, field: Image) -> void:
	_viewport.size = Vector2i(1280, 720)
	_camera.zoom = Vector2(_viewport.size) / Vector2(SIZE)
	_camera.force_update_scroll()
	var rid := _viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for coverage in [0.0, 0.92]:
		for detail in [-2, -1, 0, 1, 2]:
			var label: String = ["old_high", "inactive", "thickness", "flow", "side_light"][detail + 2]
			var mat := _material(true, false, terrain, detail != -2)
			_set_clouds(mat, coverage)
			_set_fog(mat, field, field)
			mat.set_shader_parameter("valley_fog_noise", load(NOISE))
			mat.set_shader_parameter("valley_fog_active", detail >= 0)
			mat.set_shader_parameter("valley_fog_detail", maxi(detail, 0))
			for frame in 30:
				await process_frame
				await RenderingServer.frame_post_draw
			var samples: Array[float] = []
			for frame in 90:
				await process_frame
				await RenderingServer.frame_post_draw
				var duration := RenderingServer.viewport_get_measured_render_time_gpu(rid)
				if duration > 0.0:
					samples.append(duration)
			samples.sort()
			if samples.is_empty():
				print("[valley-fog-gpu] timing unavailable for ", RenderingServer.get_current_rendering_method())
				return
			print("[valley-fog-gpu] synthetic 1280x720 cloud=%.2f %s avg=%.4f ms p95=%.4f ms n=%d %s %s" % [
				coverage, label, float(samples.reduce(func(total: float, duration: float): return total + duration, 0.0)) / samples.size(),
				samples[ceili(0.95 * samples.size()) - 1], samples.size(), RenderingServer.get_current_rendering_method(),
				RenderingServer.get_video_adapter_name()])


func _mountain_raster() -> Image:
	var image := _image(SIZE, Color.BLACK)
	for x in SIZE.x:
		var rise := clampf((38.0 - absf(x - 120.0)) / 40.0, 0.0, 1.0)
		var height := 0.18 + rise * 0.26
		if x >= 20 and x < 32:
			height = 0.05
		var bits := roundi(height * 65535.0)
		image.fill_rect(Rect2i(x, 0, 1, SIZE.y), Color(float(bits >> 8) / 255.0, float(bits & 255) / 255.0, 0, 1))
	return image


func _split_height(terrain: Image) -> Texture2DArray:
	var images: Array[Image] = []
	@warning_ignore("integer_division")
	var interior := SIZE.x / TILE_COLUMNS
	for tile in TILE_COLUMNS:
		var image := _image(Vector2i(interior + 4, SIZE.y + 4), Color.BLACK)
		for y in image.get_height():
			for x in image.get_width():
				image.set_pixel(x, y, terrain.get_pixel(posmod(tile * interior + x - 2, SIZE.x), clampi(y - 2, 0, SIZE.y - 1)))
		images.append(image)
	return _layers(images)


func _image(size: Vector2i, value: Color, format: Image.Format = Image.FORMAT_RGBA8) -> Image:
	var result := Image.create(size.x, size.y, false, format)
	result.fill(value)
	return result


func _fog_image(value: Color) -> Image:
	return _image(GRID, value, Image.FORMAT_RGH)


func _layers(images: Array[Image]) -> Texture2DArray:
	var result := Texture2DArray.new()
	var error := result.create_from_images(images)
	if error != OK:
		_expect(false, "test texture array creation failed (%d)" % error)
	return result


func _capture(label: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	if not _capture_dir.is_empty():
		image.save_png(_capture_dir.path_join(label + ".png"))
	return image


func _max_alpha_delta(a: Image, b: Image) -> float:
	var delta := 0.0
	for y in a.get_height():
		for x in a.get_width():
			delta = maxf(delta, absf(a.get_pixel(x, y).a - b.get_pixel(x, y).a))
	return delta


func _alpha_sum(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			total += image.get_pixel(x, y).a
	return total


func _expect(ok: bool, label: String) -> void:
	print("[valley-fog-render] ", "PASS " if ok else "FAIL ", label)
	if not ok:
		_failures += 1
