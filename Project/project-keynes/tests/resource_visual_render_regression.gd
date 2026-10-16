extends SceneTree

# 真 GPU 检查：实体间地面、可见/隐藏动态、horizon GI 和正式父级下的树冠遮挡。
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Fixtures = preload("res://tests/resource_visual_layer_test.gd")
const Renderer = preload("res://scripts/rendering/hex_renderer.gd")
const VisualTiles = preload("res://scripts/rendering/visual_tile_set.gd")
const TileLayout = preload("res://scripts/rendering/visual_tile_layout.gd")
const IDS = ["bio.wheat", "bio.cotton", "bio.cattle", "salt", "copper_ore", "fertile_soil"]
var failures := 0
var checks := 0
var viewport: SubViewport
var layer: Node2D
var world: WorldData
var output := "res://tmp/resource_visual_qa/integration"

func _init() -> void:
	call_deferred("run")

func run() -> void:
	output += "/" + RenderingServer.get_current_rendering_method()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport = SubViewport.new()
	viewport.size = Vector2i(720, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var renderer_root := Node2D.new()
	renderer_root.top_level = true
	renderer_root.show_behind_parent = true
	viewport.add_child(renderer_root)
	var styles := Catalog.entries()
	var map := Fixtures.make_map(styles.size(), 1)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	world = WorldData.new()
	world.world_bounds = Rect2(0, 0, 720, 128)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	world.terrain_normal_tex = _texture(Color(0.5, 0.5, 0, 1))
	layer = Layer.new()
	renderer_root.add_child(layer)
	layer.configure(map, world, 22.0, intel)
	layer._memory_image.fill(Color(0.6, 0.65, 0.0, 1.0))
	layer._memory_texture.update(layer._memory_image)
	var mat: ShaderMaterial = layer._material
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("fog_enabled", false)
	mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	mat.set_shader_parameter("tod_sun_dir", Vector3(0.65, -0.35, 0.45).normalized())
	mat.set_shader_parameter("gi_horizon_lut", Renderer.build_gi_horizon_lut(1.5708))
	mat.set_shader_parameter("terrain_horizon_max_angle", 1.5708)
	mat.set_shader_parameter("gi_lut_bound", true)
	mat.set_shader_parameter("visual_quality", 2)
	mat.set_shader_parameter("camera_zoom", 1.0)
	for col in IDS.size():
		var style := -1
		for i in styles.size():
			if styles[i].id == IDS[col]:
				style = i
		var node := MultiMeshInstance2D.new()
		node.z_index = Layer.RESOURCE_Z
		node.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = layer._mesh
		mm.instance_count = 1
		mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(48, 48), 0.0, Vector2(60 + col * 120, 64)))
		mm.set_instance_color(0, Color(0, 1, 0, Layer.KIND_DECAL if IDS[col] == "fertile_soil" else Layer.KIND_PROP))
		mm.set_instance_custom_data(0, Color(float(style), float(style), 0.45, 4.0))
		node.multimesh = mm
		layer.add_child(node)
	mat.set_shader_parameter("world_time", 0.0)
	var first := await _capture("scenery_t0")
	for col in [0, 1, 3]:
		var coverage := _coverage(first, col)
		_expect("%s leaves ground between individual forms (%.3f)" % [IDS[col], coverage], coverage > 0.01 and coverage < 0.48)
	mat.set_shader_parameter("world_time", 5.0)
	var later := await _capture("scenery_t5")
	for col in [0, 1, 2]:
		_expect("%s visibly moves" % IDS[col], _difference(first, later, col) > 0.0005)
	for col in [3, 4]:
		_expect("%s stays still" % IDS[col], _difference(first, later, col) < 0.00001)
	# 地力只在健康地表增加草被，不能把死植被/雪原强行涂绿。
	layer._memory_image.fill(Color(0.6, 0.15, 0.0, 0.0))
	layer._memory_texture.update(layer._memory_image)
	var dead := await _capture("dead_fertility")
	_expect("fertility greenery disappears when vegetation is dead", _region_alpha(dead, 5) < _region_alpha(first, 5) * 0.05)
	layer._memory_image.fill(Color(0.6, 0.65, 1.0, 1.0))
	layer._memory_texture.update(layer._memory_image)
	var snowy := await _capture("snow_fertility")
	_expect("snow suppresses fertility greenery", _region_alpha(snowy, 5) < _region_alpha(first, 5) * 0.25)
	layer._memory_image.fill(Color(0.6, 0.65, 0.0, 1.0))
	layer._memory_texture.update(layer._memory_image)
	# 当前不可见时 live=0，任何 GPU 动作都必须冻结。
	mat.set_shader_parameter("fog_enabled", true)
	mat.set_shader_parameter("enum_lut", _texture(Color(0, 0, 0, 0.5)))
	mat.set_shader_parameter("world_time", 0.0)
	var hidden_first := await _capture("hidden_t0")
	mat.set_shader_parameter("world_time", 5.0)
	var hidden_later := await _capture("hidden_t5")
	_expect("remembered scenery freezes all motion", _difference(hidden_first, hidden_later) < 0.00001)
	mat.set_shader_parameter("fog_enabled", false)
	mat.set_shader_parameter("world_time", 0.0)
	# 全方向高山遮蔽必须同时压低直射与天空光，不能只乘一个色调。
	world.terrain_horizon_tex = _texture(Color.WHITE)
	layer._sync_terrain_textures()
	var shaded := await _capture("horizon_shadow")
	_expect("horizon shadow reduces direct and sky lighting", _brightness(shaded) < _brightness(first) * 0.70)
	mat.set_shader_parameter("terrain_horizon_tex_bound", false)
	var restored := await _capture("horizon_unbound")
	_expect("missing horizon returns to neutral lighting", _difference(first, restored) < 0.00001)
	# 真实 tile array 路径；GL 用 RGBA8，Mobile/Forward 用同一 RG16 编码。
	var layout := TileLayout.new()
	layout.mode = "tiled"
	layout.visual_domain = world.world_bounds
	layout.layer_size = Vector2i(8, 8)
	layout.interior_size = Vector2i(4, 4)
	layout.logical_size = Vector2i(4, 4)
	var tiles := VisualTiles.new()
	tiles.initialize_empty(layout)
	var normals := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	normals.fill(Color(0.5, 0.5, 0, 1))
	tiles.terrain_normal.update_layer(normals, 0)
	var heights := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	heights.fill(Color(0.8, 0.0, 0.0, 0.0))
	tiles.height.update_layer(heights, 0)
	var horizon := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	horizon.fill(Color.WHITE)
	tiles.upload_horizon_layer(0, horizon.get_data())
	tiles.ready = true
	tiles.horizon_ready = true
	world.visual_tiles = tiles
	layer._sync_terrain_textures()
	var tiled_shaded := await _capture("tiled_horizon_shadow")
	_expect("tiled horizon matches legacy shadow", _difference(shaded, tiled_shaded) < 0.002)
	# 与正式 HexRenderer 相同的父级排序；树冠在资源之后/之前创建都必须挡住它。
	var canopy := ColorRect.new()
	canopy.color = Color(0.12, 0.38, 0.16, 1)
	canopy.size = Vector2(viewport.size)
	canopy.z_index = 2
	renderer_root.add_child(canopy)
	var occluded := await _capture("canopy_occlusion")
	layer.visible = false
	var canopy_only := await _capture("canopy_only")
	_expect("tree canopy occludes every resource pixel", _difference(occluded, canopy_only) < 0.00001)
	layer.visible = true
	canopy.queue_free()
	world.visual_tiles = null
	layer._sync_terrain_textures()
	mat.set_shader_parameter("terrain_horizon_tex_bound", false)
	# 放大的群落按像素避让河体，干燥一侧的植物仍可见。
	for y in 8:
		for x in 4:
			heights.set_pixel(x, y, Color(0.8, 0.0, 1.0, 0.0))
	world.height_tex = ImageTexture.create_from_image(heights)
	world.flow_buffer = PackedFloat32Array([1.0])
	layer._sync_terrain_textures()
	mat.set_shader_parameter("terrain_horizon_tex_bound", false)
	var river_masked := await _capture("river_footprint_clip")
	_expect("wide plant patches clip river pixels while keeping dry ground", _region_alpha(river_masked, 0) < 0.01 and _region_alpha(river_masked, 5) > 0.5)
	world.height_tex = null
	world.flow_buffer = PackedFloat32Array()
	layer._sync_terrain_textures()
	mat.set_shader_parameter("terrain_horizon_tex_bound", false)
	mat.set_shader_parameter("lens_amount", 1.0)
	mat.set_shader_parameter("hex_size", 200.0)
	mat.set_shader_parameter("badge_px", 96.0)
	var badges := await _capture("lens_badges")
	_expect("recognition badges keep their complete silhouettes", _coverage(badges, 0) > 0.55)
	print("resource render regression: %d checks, %d failures; %s" % [checks, failures, output])
	viewport.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _texture(color: Color) -> ImageTexture:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func _capture(name: String) -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output + "/" + name + ".png")
	return image

func _coverage(image: Image, col: int) -> float:
	var filled := 0
	for y in range(20, 108):
		for x in range(col * 120 + 16, col * 120 + 104):
			filled += 1 if image.get_pixel(x, y).a > 0.2 else 0
	return float(filled) / (88.0 * 88.0)

func _region_alpha(image: Image, col: int) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in range(col * 120, col * 120 + 120):
			total += image.get_pixel(x, y).a
	return total

func _difference(a: Image, b: Image, col: int = -1) -> float:
	var total := 0.0
	var lo := col * 120 if col >= 0 else 0
	var hi := lo + 120 if col >= 0 else a.get_width()
	for y in a.get_height():
		for x in range(lo, hi):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			total += absf(p.r * p.a - q.r * q.a) + absf(p.g * p.a - q.g * q.a) + absf(p.b * p.a - q.b * q.a) + absf(p.a - q.a)
	return total / float((hi - lo) * a.get_height())

func _brightness(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var p := image.get_pixel(x, y)
			total += (p.r + p.g + p.b) * p.a
	return total

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[PASS] " if ok else "[FAIL] ", label)
