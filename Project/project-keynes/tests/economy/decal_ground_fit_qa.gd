extends SceneTree

# [decal-ground-fit 2026-11-18] 贴花贴合地表的 A/B 对比。
#
# 同一块坡面（左平右陡）上放三块地力/耕地贴花，四种参数各渲一次：
#   A before  slope_fit=0, ground_tint=0    → 改造前：印在屏幕平面上的贴纸
#   B slope   slope_fit=1, ground_tint=0    → 只加坡度面积变形
#   C tint    slope_fit=0, ground_tint=0.45 → 只加地表颜色继承
#   D both    slope_fit=1, ground_tint=0.45 → 两者同时
#
# 出图：tmp/decal_ground_fit_qa/<rendering_method>/decal_ab.png（四联竖排）
#
# 这是 QA 夹具，不是回归测试：不写 PASS/FAIL，只负责让眼睛判断。

const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")

const IDS = ["arable_land", "fertile_soil", "pasture", "bio.wheat"]
const W := 720
const H := 128

var viewport: SubViewport
var layer: Node2D
var world: WorldData
var output := "res://tmp/decal_ground_fit_qa"

func _init() -> void:
	call_deferred("run")

func run() -> void:
	output += "/" + RenderingServer.get_current_rendering_method()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport = SubViewport.new()
	viewport.size = Vector2i(W, H)
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
	world.world_bounds = Rect2(0, 0, W, H)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	world.sea_level = 0.42
	world.height_tex = _height_field()
	world.terrain_normal_tex = _slope_field()
	layer = Layer.new()
	renderer_root.add_child(layer)
	layer.configure(map, world, 22.0, intel)
	layer._memory_image.fill(Color(0.62, 0.68, 0.0, 1.0))
	layer._memory_texture.update(layer._memory_image)
	var mat: ShaderMaterial = layer._material
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("fog_enabled", false)
	mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	mat.set_shader_parameter("tod_sun_dir", Vector3(0.55, -0.45, 0.52).normalized())
	mat.set_shader_parameter("visual_quality", 2)
	mat.set_shader_parameter("camera_zoom", 1.0)
	mat.set_shader_parameter("world_time", 0.0)
	# 抬到接近不透明，判读贴花自身的形状与色温；世界内实测值是 0.60。
	mat.set_shader_parameter("decal_opacity", 0.92)
	for col in IDS.size():
		var style := -1
		for i in styles.size():
			if String(styles[i].id) == IDS[col]:
				style = i
		if style < 0:
			push_error("missing style " + IDS[col])
			quit(1)
			return
		var node := MultiMeshInstance2D.new()
		node.z_index = Layer.RESOURCE_Z
		node.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = layer._mesh
		mm.instance_count = 1
		mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(96, 96), 0.0,
			Vector2(90 + col * 180, 64)))
		mm.set_instance_color(0, Color(0, 1, 0,
			Layer.KIND_DECAL if col < 3 else Layer.KIND_PROP))
		mm.set_instance_custom_data(0, Color(float(style), float(style), 0.45, 4.0))
		node.multimesh = mm
		layer.add_child(node)
	print("[qa] configured=", layer._configured,
		" material=", layer._material != null,
		" art_material_bound=", mat.get_shader_parameter("art_material_bound"),
		" has_height_tex=", mat.get_shader_parameter("has_height_tex"),
		" terrain_normal_tex_bound=", mat.get_shader_parameter("terrain_normal_tex_bound"),
		" kind_decal=", Layer.KIND_DECAL,
		" styles=", styles.size())
	var lut_tex = mat.get_shader_parameter("style_lut")
	if lut_tex is ImageTexture:
		var lut: Image = lut_tex.get_image()
		for probe in [22, 23, 26]:
			print("[qa] style ", probe, " color=", styles[probe].color,
				" lut_col1=", lut.get_pixel(1, probe),
				" lut_col0=", lut.get_pixel(0, probe),
				" lut_col3=", lut.get_pixel(3, probe))
	var shots: Array[Image] = []
	for variant in [["A_before", 0.0, 0.0], ["B_slope", 1.0, 0.0],
			["C_tint", 0.0, 0.45], ["D_both", 1.0, 0.45],
			["E_slope3_tint", 3.0, 0.45], ["F_slope3", 3.0, 0.0]]:
		mat.set_shader_parameter("decal_slope_fit", float(variant[1]))
		mat.set_shader_parameter("decal_ground_tint", float(variant[2]))
		shots.append(await _capture(String(variant[0])))
	_sheet(shots, output + "/decal_ab.png")
	print("decal ground fit QA: ", output, "/decal_ab.png")
	quit(0)

## 高度场：左低右高（0.46 → 0.80）。
## shader 的读取式是 `(r*256 + g)/257`，8-bit 纹理下 R 就是高位主值，
## 低字节只贡献 1/257 的精度 —— 写进 G 会被读成接近 0，整块被当水面裁掉。
func _height_field() -> ImageTexture:
	var image := Image.create(W, H, false, Image.FORMAT_RGBA8)
	for y in H:
		for x in W:
			var h := lerpf(0.46, 0.80, float(x) / float(W - 1))
			image.set_pixel(x, y, Color(h, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(image)

## 地形法线：坡度从左 0 线性增到右 1.0（编码 rg = n*0.5+0.5）。
## rv_terrain_normal_at 内部还要再乘 0.65，所以最陡处 xy ≈ 0.65、nz ≈ 0.76。
func _slope_field() -> ImageTexture:
	var image := Image.create(W, H, false, Image.FORMAT_RGBA8)
	for y in H:
		for x in W:
			var sx := float(x) / float(W - 1)
			image.set_pixel(x, y, Color(0.5 + sx * 0.5, 0.5, 0.0, 1.0))
	return ImageTexture.create_from_image(image)

func _capture(name: String) -> Image:
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output + "/" + name + ".png")
	return image

func _sheet(images: Array[Image], path: String) -> void:
	var cols := 2
	var rows := ceili(float(images.size()) / float(cols))
	var sheet := Image.create(W * cols, H * rows, false, Image.FORMAT_RGBA8)
	for i in images.size():
		sheet.blit_rect(images[i], Rect2i(0, 0, W, H),
			Vector2i((i % cols) * W, (i / cols) * H))
	sheet.save_png(path)
