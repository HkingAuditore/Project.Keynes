extends "res://tests/world/fog_cell_field_test.gd"
## 真实 GPU 回归：相邻格的遮罩连续变化，孤立可见格中心清晰，深未知不透明。
## 可选 -- --baseline=<修改前 shader 绝对路径> --output=<输出目录>，输出固定条件 A/B。

func _run() -> void:
	if not _real_backend_available():
		push_error("fog_continuous_mask_test requires a real rendering backend")
		quit(1)
		return
	var output := "user://fog-continuous-mask"
	var baseline := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
		if arg.begins_with("--baseline="):
			baseline = arg.trim_prefix("--baseline=")
	DirAccess.make_dir_recursive_absolute(output)
	var layer := Image.create_empty(MAP_W, MAP_H, false, Image.FORMAT_RGBA8)
	for row in MAP_H:
		for col in MAP_W:
			layer.set_pixel(col, row, Color(float(col % 2), 0, 0, 0))
	var world := _assemble_world(layer, Vector2i(MAP_W, MAP_H))
	var host := _FakeFogHost.new()
	host._world = world
	host._shader_mat = _build_host_material(false, 0.02)
	root.add_child(host)
	var fog := FogOfWarLayer.new()
	host.add_child(fog)
	fog.setup(Rect2(ORIGIN, Vector2(VIEW_W, VIEW_H)), DataOverlayBaker.get_empty_texture(),
		Vector2i(MAP_W, MAP_H), HEX_SIZE, 0.0)
	await process_frame
	var mat: ShaderMaterial = fog.get("_shader_mat")
	var viewport := await _build_probe_scene(mat, ORIGIN, Vector2(VIEW_W, VIEW_H))
	# 关闭扰动以单独检查插值，不让噪声掩盖格内平台。
	fog.set_process(false)
	mat.set_shader_parameter("fog_warp_amp", 0.0)
	mat.set_shader_parameter("fog_debug_view", VIEW_K)
	var image := await _render(viewport)
	var changing := 0
	var total := 0
	# row=2 的格心连线，避开格心保护区；同一行相邻格知识度为 0 和 1。
	for x in range(146, 158):
		total += 1
		if absf(image.get_pixel(x + 1, 66).r - image.get_pixel(x, 66).r) > 0.004:
			changing += 1
	_expect(changing == total, "continuous mask changes between centers: %d/%d" % [changing, total])
	if not baseline.is_empty():
		var current_shader := mat.shader
		var old_shader := Shader.new()
		old_shader.code = current_shader.code.substr(0, current_shader.code.find("shader_type")) \
			+ FileAccess.get_file_as_string(baseline)
		mat.shader = old_shader
		var old_image := await _render(viewport)
		var old_changing := 0
		for x in range(146, 158):
			if absf(old_image.get_pixel(x + 1, 66).r - old_image.get_pixel(x, 66).r) > 0.004:
				old_changing += 1
		print("[fog-mask] baseline changing segments: %d/%d" % [old_changing, total])
		mat.shader = current_shader
	mat.set_shader_parameter("fog_warp_amp", FogOfWarLayer.FOG_WARP_AMP)
	mat.set_shader_parameter("fog_debug_view", VIEW_ALPHA)
	image = await _render(viewport)
	var bad_centers := 0
	var centers := 0
	for row in range(1, 7):
		for col in range(-2, 5):
			var point := Vector2(sqrt(3.0) * HEX_SIZE * (col + 0.5 * (row & 1)),
				1.5 * HEX_SIZE * row) - ORIGIN
			var pixel := Vector2i(point.floor())
			if pixel.x < 0 or pixel.x >= VIEW_W or pixel.y >= VIEW_H:
				continue
			centers += 1
			var alpha := image.get_pixelv(pixel).r
			if (col & 1) == 1 and alpha > ALPHA_CLEAR_MAX:
				bad_centers += 1
			if (col & 1) == 0 and alpha < float(ALPHA_OPAQUE_MIN) / 255.0:
				bad_centers += 1
	_expect(centers > 20 and bad_centers == 0,
		"mixed visible/unknown centers preserved: %d bad / %d" % [bad_centers, centers])
	# 线性知识度场不应长出格心斑点。关闭噪声，检查整片二维区域而非只查格心。
	var affine_bytes := PackedByteArray()
	affine_bytes.resize(MAP_W * MAP_H * 4)
	for row in MAP_H:
		for col in MAP_W:
			affine_bytes[(row * MAP_W + col) * 4] = mini(32 + 8 * col + 4 * (row & 1), 255)
	layer = Image.create_from_data(MAP_W, MAP_H, false, Image.FORMAT_RGBA8, affine_bytes)
	world = _assemble_world(layer, Vector2i(MAP_W, MAP_H))
	mat.set_shader_parameter("cell_table", world.cell_table_tex)
	mat.set_shader_parameter("fog_warp_amp", 0.0)
	mat.set_shader_parameter("fog_debug_view", VIEW_K)
	image = await _render(viewport)
	var affine_error := _affine_mask_error(image)
	# 精确字节输入：容差只覆盖 8bit 回读的半级误差与相机亚像素对齐。
	_expect(affine_error < 0.0025,
		"affine field has no grid-center opacity spots (max error %.6f)" % affine_error)
	if not baseline.is_empty():
		var current_shader := mat.shader
		var old_shader := Shader.new()
		old_shader.code = current_shader.code.substr(0, current_shader.code.find("shader_type")) \
			+ FileAccess.get_file_as_string(baseline)
		mat.shader = old_shader
		var old_error := _affine_mask_error(await _render(viewport))
		_expect(old_error >= 0.0025,
			"baseline reproduces grid-center spots (max error %.6f)" % old_error)
		mat.shader = current_shader
	mat.set_shader_parameter("fog_warp_amp", FogOfWarLayer.FOG_WARP_AMP)
	# 固定的同心视野，模拟两轮邻域柔化后的离散知识度。
	for row in MAP_H:
		for col in MAP_W:
			var delta := Vector2(col + 0.5 * (row & 1) - 12.0, (row - 10.0) * 0.8660254)
			var k := clampf((7.0 - delta.length()) / 3.0, 0.0, 1.0)
			layer.set_pixel(col, row, Color(k, 0, 0, 0))
	world = _assemble_world(layer, Vector2i(MAP_W, MAP_H))
	mat.set_shader_parameter("cell_table", world.cell_table_tex)
	mat.set_shader_parameter("fog_debug_view", 0)
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("world_time", 17.0)
	mat.set_shader_parameter("fog_quality", 2)
	viewport.queue_free()
	viewport = await _build_probe_scene(mat, Vector2(80, -30), Vector2(760, 720))
	var original_shader := mat.shader
	var prefix := original_shader.code.substr(0, original_shader.code.find("shader_type"))
	var shaders: Array[Shader] = []
	var baseline_freq := FogOfWarLayer.FOG_WARP_FREQ
	if not baseline.is_empty():
		var before := Shader.new()
		before.code = prefix + FileAccess.get_file_as_string(baseline)
		var frequency := RegEx.new()
		frequency.compile("uniform float fog_warp_freq\\s*=\\s*([0-9.]+)")
		var matched := frequency.search(before.code)
		if matched != null:
			baseline_freq = float(matched.get_string(1))
		shaders.append(before)
	shaders.append(original_shader)
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	var samples := {}
	for pass_index in range(shaders.size() * 2):
		var index := pass_index % shaders.size() if pass_index < shaders.size() else shaders.size() * 2 - pass_index - 1
		var label := "after" if index == shaders.size() - 1 else "before"
		mat.shader = shaders[index]
		mat.set_shader_parameter("fog_warp_freq", FogOfWarLayer.FOG_WARP_FREQ if label == "after" else baseline_freq)
		for frame in 30:
			await process_frame
		image = await _render(viewport)
		image.save_png(output.path_join(label + ".png"))
		mat.set_shader_parameter("fog_debug_view", VIEW_K)
		var mask := await _render(viewport)
		mask.save_png(output.path_join(label + "_mask.png"))
		if label == "after":
			_check_cloud_contour(mask)
		mat.set_shader_parameter("fog_debug_view", 0)
		await _render(viewport)
		var times: Array = samples.get(label, [])
		for frame in 90:
			await process_frame
			await RenderingServer.frame_post_draw
			times.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()))
		samples[label] = times
	for label in samples:
		var times: Array = samples[label]
		times.sort()
		print("[fog-mask] %s GPU median=%.4f ms p95=%.4f ms n=%d adapter=%s" % [
			label, times[times.size() / 2], times[int(times.size() * 0.95)], times.size(),
			RenderingServer.get_video_adapter_name()])
	viewport.queue_free()
	host.queue_free()
	await process_frame
	print("[fog-mask] %d checks, %d failures; output=%s" % [_checks, _failures, output])
	quit(0 if _failures == 0 else 1)


func _affine_mask_error(image: Image) -> float:
	var error := 0.0
	for y in range(40, 210):
		for x in range(170, 310):
			var expected := (32.0 + 8.0 * (ORIGIN.x + x + 0.5) / (sqrt(3.0) * HEX_SIZE)) / 255.0
			error = maxf(error, absf(image.get_pixel(x, y).r - expected))
	return error


func _check_cloud_contour(mask: Image) -> void:
	# 合成源是圆形；显示边缘仍须有云团尺度的凹凸，不能只消点后抹成圆。
	var center := Vector2(sqrt(3.0) * HEX_SIZE * 12.0 - 80.0, 360.0)
	var min_radius := 1000.0
	var max_radius := 0.0
	for ray in 48:
		var direction := Vector2.from_angle(TAU * float(ray) / 48.0)
		for radius in range(120, 300):
			var pixel := Vector2i((center + direction * radius).floor())
			if mask.get_pixelv(pixel).r < 0.5:
				min_radius = minf(min_radius, radius)
				max_radius = maxf(max_radius, radius)
				break
	_expect(max_radius - min_radius > HEX_SIZE,
		"cloud-scale contour relief survives smoothing (radius span %.1f world units)" % (max_radius - min_radius))
