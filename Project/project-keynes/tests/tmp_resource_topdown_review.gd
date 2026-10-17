extends SceneTree

# Temporary art-review harness: renders every land style at 2x scale on a map-like
# green and on dry grass, then the same grid with the lens badges enabled.
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Fixtures = preload("res://tests/resource_visual_layer_test.gd")

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var styles := Catalog.entries()
	var land: Array[int] = []
	for i in styles.size():
		if int(styles[i].family) != 3:
			land.append(i)
	var cols := 7
	var rows := ceili(float(land.size()) / float(cols))
	var tile := 150.0
	var size := Vector2i(int(cols * tile), int(rows * tile))
	var map := Fixtures.make_map(styles.size(), 1)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	for cell in styles.size():
		var bands := PackedByteArray()
		bands.resize(styles.size())
		bands[cell] = 4
		intel.resource_observations.rows[cell] = {"bands": bands, "climate": Color(0.6, 0.65, 0.0, 1.0)}
	var world := WorldData.new()
	world.world_bounds = Rect2(0, 0, size.x, size.y)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	var output := "res://tmp/resource_visual_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	for variant in 4:
		var viewport := SubViewport.new()
		viewport.size = size
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var background := ColorRect.new()
		background.size = Vector2(size)
		background.color = Color("4f7a34") if variant % 2 == 0 else Color("a39448")
		viewport.add_child(background)
		var layer := Layer.new()
		viewport.add_child(layer)
		layer.configure(map, world, 22.0, intel)
		layer.set_context(false, 7931)
		layer.set_quality(2)
		layer._material.set_shader_parameter("day_night_enabled", false)
		layer._material.set_shader_parameter("fog_enabled", false)
		layer._material.set_shader_parameter("camera_zoom", 1.0)
		layer._material.set_shader_parameter("tod_debug_sun_position_enabled", true)
		layer._material.set_shader_parameter("tod_sun_dir", Vector3(-0.45, -0.35, 0.82).normalized())
		layer._material.set_shader_parameter("lens_amount", 1.0 if variant >= 2 else 0.0)
		layer._material.set_shader_parameter("badge_px", 96.0)
		layer._material.set_shader_parameter("hex_size", 400.0)
		for n in land.size():
			var style := land[n]
			var center := Vector2((float(n % cols) + 0.5) * tile, (float(n / cols) + 0.5) * tile)
			var radius := 62.0
			var node := MultiMeshInstance2D.new()
			node.z_index = 1
			node.material = layer._material
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_2D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = layer._mesh
			mm.instance_count = 1
			mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(radius, radius), 0.0, center))
			mm.set_instance_color(0, Color(0, 0, 0, 1))
			mm.set_instance_custom_data(0, Color(float(style), float(style), 0.45, 4.0))
			node.multimesh = mm
			viewport.add_child(node)
		for frame in 6:
			layer.drain_one_upload()
			await process_frame
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output + "/topdown_review_%d.png" % variant)
		viewport.queue_free()
		await process_frame
	print("topdown review written")
	quit()
