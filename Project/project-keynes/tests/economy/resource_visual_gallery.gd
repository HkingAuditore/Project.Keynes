extends SceneTree

const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 1000)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var background := ColorRect.new()
	background.color = Color("72745a")
	background.size = Vector2(1440, 1000)
	background.z_index = -5
	viewport.add_child(background)
	var styles := Catalog.entries()
	var map := Fixtures.make_map(9, 6)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	for i in styles.size():
		var col := i % 9
		var row := i / 9
		var center := Vector2(80 + col * 160, 90 + row * 158)
		map.is_water_arr[i] = 1 if int(styles[i].family) == 3 else 0
		map.cell_pos_x_arr[i] = center.x / 100.0
		map.cell_pos_y_arr[i] = center.y / 100.0
		var bands := PackedByteArray()
		bands.resize(styles.size())
		bands[i] = 4
		intel.resource_observations.rows[i] = {"bands": bands, "climate": Color(0.6, 0.65, 0.0, 1.0)}
		var label := Label.new()
		label.text = String(styles[i].display_name) + "\n" + String(styles[i].id)
		label.position = Vector2(col * 160 + 7, row * 158 + 126)
		label.z_index = 5
		label.add_theme_font_size_override("font_size", 15)
		label.modulate = Color("eee5c8")
		viewport.add_child(label)
	var world := WorldData.new()
	world.world_bounds = Rect2(0, 0, 1440, 1000)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	var layer := Layer.new()
	viewport.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	layer.profile.patch_diameter_hex = 0.60
	layer.profile.density_scale = 2.0
	layer.profile.cluster_spread = 0.1
	layer.profile.per_cell_caps = PackedInt32Array([2, 2, 2])
	layer.configure(map, world, 100.0, intel)
	layer.set_context(false, 7931)
	layer.set_quality(2)
	layer.set_camera_view(world.world_bounds, world.world_bounds.get_center(), 1.0)
	layer._material.set_shader_parameter("day_night_enabled", false)
	layer._material.set_shader_parameter("fog_enabled", false)
	# Isolated fish silhouettes are previewed through a blue water veil here.
	# The actual game uses water_pipeline's transmitted base colour, not these
	# preview quads; resource_visual_world_qa exercises that composition.
	for i in styles.size():
		if int(styles[i].family) != 3:
			continue
		var tile := Vector2(float(i % 9) * 160.0, float(i / 9) * 158.0)
		var water := ColorRect.new()
		water.position = tile + Vector2(8, 4)
		water.size = Vector2(144, 120)
		water.color = Color("476d7e")
		viewport.add_child(water)
		var raw := MultiMeshInstance2D.new()
		raw.z_index = 1
		raw.material = layer._material
		var raw_mm := MultiMesh.new()
		raw_mm.transform_format = MultiMesh.TRANSFORM_2D
		raw_mm.use_colors = true
		raw_mm.use_custom_data = true
		raw_mm.mesh = layer._mesh
		raw_mm.instance_count = 1
		raw_mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(40, 40), 0.0, tile + Vector2(80, 65)))
		raw_mm.set_instance_color(0, Color(0, 1, 0, 1))
		raw_mm.set_instance_custom_data(0, Color(float(i), float(i), 0.3, 4.0))
		raw.multimesh = raw_mm
		viewport.add_child(raw)
		var veil := ColorRect.new()
		veil.position = water.position
		veil.size = water.size
		veil.color = Color(0.20, 0.40, 0.52, 0.35)
		veil.z_index = 2
		viewport.add_child(veil)
	for frame in 80:
		layer._build_until(Time.get_ticks_usec() + 10000)
		layer.drain_one_upload()
		await process_frame
	var output := "res://tmp/resource_visual_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("resource gallery: renderer did not produce an image")
		quit(1)
		return
	image.save_png(output + "/catalog.png")
	layer._material.set_shader_parameter("tod_debug_sun_position_enabled", true)
	layer._material.set_shader_parameter("day_night_enabled", true)
	layer._material.set_shader_parameter("tod_sun_dir", Vector3(0.8, 0.4, 0.18).normalized())
	await process_frame
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output + "/low_sun.png")
	layer._material.set_shader_parameter("tod_sun_dir", Vector3(0.4, -0.5, -0.7).normalized())
	await process_frame
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output + "/night.png")
	layer._material.set_shader_parameter("tod_sun_dir", Vector3(0.4, -0.5, 0.8).normalized())
	layer._memory_image.fill(Color(0.2, 0.4, 0.85, 0.7))
	layer._memory_texture.update(layer._memory_image)
	await process_frame
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output + "/snow.png")
	layer._memory_image.fill(Color(0.6, 0.65, 0.0, 1.0))
	layer._memory_texture.update(layer._memory_image)
	layer._material.set_shader_parameter("tod_debug_sun_position_enabled", false)
	layer._material.set_shader_parameter("day_night_enabled", false)
	# GPU A/B in the same viewport, with resource visibility as the sole change.
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	var on := []
	var off := []
	for enabled in [false, true]:
		layer.visible = enabled
		for frame in 45:
			await process_frame
			if frame >= 15:
				var value := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
				if enabled: on.append(value)
				else: off.append(value)
	on.sort()
	off.sort()
	var device := RenderingServer.get_video_adapter_name()
	var report := {"device": device, "renderer": RenderingServer.get_current_rendering_method(),
		"viewport": "1440x1000", "on_gpu_median_ms": on[on.size() / 2],
		"off_gpu_median_ms": off[off.size() / 2], "layer": layer.diagnostics()}
	# Deliberately dense, 20k-instance shader stress, separate from gallery and
	# from normal per-cell distribution. It measures overdraw and lighting cost.
	layer.visible = false
	var stress := MultiMeshInstance2D.new()
	stress.material = layer._material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = layer._mesh
	mm.instance_count = 20000
	for i in 20000:
		var x := float(i % 160) * 9.0 + 4.5
		var y := float(i / 160) * 8.0 + 4.0
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2(8, 8), 0.0, Vector2(x, y)))
		mm.set_instance_color(i, Color(0, 0, 0, 1))
		mm.set_instance_custom_data(i, Color(float(i % 51), float(i % 51), float(i % 97) / 97.0, 4.0))
	stress.multimesh = mm
	viewport.add_child(stress)
	var stress_samples := []
	for frame in 60:
		await process_frame
		if frame >= 20:
			stress_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()))
	stress_samples.sort()
	report["stress_instances"] = 20000
	report["stress_gpu_median_ms"] = stress_samples[stress_samples.size() / 2]
	print("resource gallery: ", JSON.stringify(report))
	var file := FileAccess.open(output + "/gallery_metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	viewport.queue_free()
	await process_frame
	quit()
