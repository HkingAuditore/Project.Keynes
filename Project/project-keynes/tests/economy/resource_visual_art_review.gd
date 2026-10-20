extends SceneTree

const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")

func _init() -> void:
	call_deferred("run")

# 原始像素直接由引擎绘制；放大栏单独重绘，不用图片缩放冒充游戏大小。
func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 1140)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var background := ColorRect.new()
	background.size = viewport.size
	background.color = Color("272e29")
	viewport.add_child(background)
	_label(viewport, "资源 45° 造型 · 引擎实绘尺寸校样", Vector2(28, 16), 25)
	_label(viewport, "统一日照、健康植株、无积雪", Vector2(930, 25), 15)
	_label(viewport, "地图 3× · 原始像素", Vector2(240, 65), 18)
	_label(viewport, "近景 6× · 原始像素", Vector2(650, 65), 18)
	_label(viewport, "造型放大检查", Vector2(1110, 65), 18)
	var styles := Catalog.entries()
	var chosen := ["bio.wheat", "bio.maize", "bio.rice", "bio.cattle", "bio.sheep", "bio.pig", "bio.horse", "bio.camel", "copper_ore", "oil"]
	var map := Fixtures.make_map(styles.size(), 1)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	for cell in styles.size():
		var bands := PackedByteArray()
		bands.resize(styles.size())
		bands[cell] = 4
		intel.resource_observations.rows[cell] = {"bands": bands, "climate": Color(0.6, 0.65, 0.0, 1.0)}
	var world := WorldData.new()
	world.world_bounds = Rect2(0, 0, 1440, 1140)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	var layer := Layer.new()
	viewport.add_child(layer)
	layer.configure(map, world, 22.0, intel)
	layer.set_context(false, 7931)
	layer._material.set_shader_parameter("day_night_enabled", false)
	layer._material.set_shader_parameter("fog_enabled", false)
	layer._material.set_shader_parameter("camera_zoom", 1.0)
	for row in chosen.size():
		var style := -1
		for i in styles.size():
			if String(styles[i].id) == chosen[row]:
				style = i
		var y := 108.0 + float(row) * 100.0
		_label(viewport, String(styles[style].display_name), Vector2(30, y + 28), 21)
		for column in 3:
			var tile := ColorRect.new()
			tile.position = Vector2(200 + column * 410, y)
			tile.size = Vector2(390, 94)
			tile.color = Color("68745a")
			tile.z_index = 0
			viewport.add_child(tile)
			var factor: float = [3.0, 6.0, 14.0][column]
			var radius := 22.0 * float(layer.profile.patch_diameter_hex) * 0.5 * factor * (1.18 if int(styles[style].family) == 1 else 1.0)
			if column == 2:
				radius = minf(radius, 60.0)
			var node := MultiMeshInstance2D.new()
			node.z_index = 1
			node.material = layer._material
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_2D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = layer._mesh
			mm.instance_count = 1
			mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(radius, radius), 0.0, tile.position + tile.size * 0.5 + Vector2(0, 4)))
			mm.set_instance_color(0, Color(0, 0, 0, 1))
			mm.set_instance_custom_data(0, Color(float(style), float(style), 0.45, 4.0))
			node.multimesh = mm
			viewport.add_child(node)
	for frame in 4:
		layer.drain_one_upload()
		await process_frame
	await RenderingServer.frame_post_draw
	var output := "res://tmp/resource_visual_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport.get_texture().get_image().save_png(output + "/art_review_45.png")
	print("resource art review: ", output + "/art_review_45.png")
	viewport.queue_free()
	await process_frame
	quit()

func _label(parent: Node, text: String, position: Vector2, font_size: int) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.z_index = 5
	label.add_theme_font_size_override("font_size", font_size)
	label.modulate = Color("e9e5cf")
	parent.add_child(label)
