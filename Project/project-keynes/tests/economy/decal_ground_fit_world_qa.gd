extends SceneTree

# [decal-ground-fit 2026-11-18] 正式新游戏场景里的贴花 A/B。
#
# 同一相机位、同一太阳、同一时刻，只改两个 uniform，拼成 2x2：
#   左上 A before  slope_fit=0, ground_tint=0      → 改造前
#   右上 B slope   slope_fit=1, ground_tint=0      → 只加坡度面积变形
#   左下 C tint    slope_fit=0, ground_tint=0.45   → 只加地表色继承
#   右下 D both    slope_fit=1, ground_tint=0.45   → 两者同时
#
# 出图：tmp/decal_ground_fit_qa/world_decal_ab.png
# 这是 QA 夹具，不写 PASS/FAIL。

const MAX_WAIT_MS := 180000

func _init() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1440, 900)
	var flow := root.get_node("GameFlow")
	var config := NewGameConfig.new()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var request: Dictionary = flow.begin_new_game(config)
	if not bool(request.get("ok", false)):
		push_error(str(request))
		quit(1)
		return
	var host: WorldRuntimeHost
	var deadline := Time.get_ticks_msec() + MAX_WAIT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene is PlayerGame:
			host = current_scene.get_node("RuntimeHost")
			if host.current_map() != null and bool(host.generator().gameplay_start_report().get("ok", false)) \
					and bool(host.get("_runtime_ready_for_ticks")):
				break
	if host == null or host.current_map() == null:
		push_error("decal world QA timed out")
		quit(1)
		return
	var game := current_scene
	game.get_node("WorldClock").pause(true)
	game.get_node("UI").visible = false
	var renderer := host.get_renderer()
	renderer.set_day_night_enabled(false)
	host.set_fog_of_war_enabled(false)
	var layer = renderer._resource_visual_layer
	if layer == null or layer._material == null:
		push_error("resource visual layer missing")
		quit(1)
		return
	var mat: ShaderMaterial = layer._material
	print("[qa] terrain_normal_bound=", mat.get_shader_parameter("terrain_normal_tex_bound"),
		" has_height_tex=", mat.get_shader_parameter("has_height_tex"),
		" has_flow_tex=", mat.get_shader_parameter("has_flow_tex"),
		" decal_opacity=", mat.get_shader_parameter("decal_opacity"),
		" contact_shadow=", mat.get_shader_parameter("contact_shadow"),
		" height_scale=", mat.get_shader_parameter("terrain_normal_height_scale_hex"))
	_report_normal_range(host, layer)
	# 固定太阳高度角：四张图只差贴花参数，不受晨昏线移动干扰。
	mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	mat.set_shader_parameter("tod_sun_dir", Vector3(0.62, -0.42, 0.40).normalized())
	# QA 增强：世界内默认 0.60，且 form 22 还乘活力曲线；拉到 0.95 才能看清形态。
	# 这一项只影响判读，不是游戏内实际值。
	mat.set_shader_parameter("decal_opacity", 0.95)
	var map := host.current_map()
	var camera := game.get_node("MapCamera") as Camera2D
	# 直接按地力储量选格：稳定，不依赖 chunk 什么时候建出来。
	var cell := -1
	var best := 0.0
	for c in map.cell_count():
		if map.is_water_arr[c] != 0:
			continue
		var reserve := float(map.res_fertile_soil_reserve_arr[c])
		if reserve <= 0.0:
			continue
		# form 22 的落笔 alpha 还乘一条活力曲线：低活力格上贴花本就会被设计成"退隐"。
		# QA 要判读形状，必须挑一块同时有储量和活力的地。
		var score := reserve * clampf(float(map.vegetation_vitality_arr[c]), 0.0, 1.0)
		if score > best:
			best = score
			cell = c
	if cell < 0:
		cell = 0
	var decal_point := Vector2(map.cell_pos_x_arr[cell], map.cell_pos_y_arr[cell]) * renderer.hex_size
	print("[qa] target cell=", cell, " score=", best,
		" reserve=", map.res_fertile_soil_reserve_arr[cell],
		" vitality=", map.vegetation_vitality_arr[cell], " point=", decal_point)
	camera.call("_stop_motion")
	camera.position = decal_point
	camera.set("_pan_anim_target", decal_point)
	camera.set("_pan_anim_active", false)
	camera.zoom = Vector2(6.0, 6.0)
	camera.set("_target_zoom", Vector2(6.0, 6.0))
	# pk_debug.cfg 里的截图倍率会把 zoom 每帧压回旧值，QA 里显式清掉。
	camera.set("_qa_zoom", 0.0)
	camera.set("_qa_zoom_until_ms", 0)
	for frame in 180:
		await process_frame
	print("[qa] zoom=", camera.zoom, " pos=", camera.position,
		" hex=", renderer.hex_size, " layer_zoom=", layer._zoom)
	var output := "res://tmp/decal_ground_fit_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var shots: Array[Image] = []
	# E/F 是夸张验证：slope_fit=3.0 只用来确认变形链路通不通，
	# 真实地形法线幅度下 1.0 就够（超出物理值是过冲）。
	for variant in [["A_before", 0.0, 0.0], ["B_slope", 1.0, 0.0],
			["C_tint", 0.0, 0.45], ["D_both", 1.0, 0.45],
			["E_slope3_tint", 3.0, 0.45], ["F_slope3", 3.0, 0.0]]:
		mat.set_shader_parameter("decal_slope_fit", float(variant[1]))
		mat.set_shader_parameter("decal_ground_tint", float(variant[2]))
		mat.set_shader_parameter("decal_opacity", 0.95)
		for frame in 30:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.save_png(output + "/world_" + String(variant[0]) + ".png")
		shots.append(image)
	_grid(shots, output + "/world_decal_ab.png")
	print("decal world A/B: ", output, "/world_decal_ab.png")
	quit(0)

## 烘焙法线的真实幅度：RG 编码 0.5 = 完全平坦。用来判断竖直夸张参数有没有生效
## （预烘瓦片存在时，改 MapBaker 常量不会重烘，幅度会原样不动）。
func _report_normal_range(host, layer) -> void:
	var img: Image = null
	if layer._world != null:
		if layer._world.terrain_normal_tex != null:
			img = layer._world.terrain_normal_tex.get_image()
		elif layer._world.visual_tiles != null and layer._world.visual_tiles.terrain_normal != null:
			img = layer._world.visual_tiles.terrain_normal.get_layer_data(0)
	if img == null:
		print("[qa] terrain normal: none")
		return
	var lo := 1.0
	var hi := 0.0
	var step := maxi(1, img.get_width() / 128)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			lo = minf(lo, minf(c.r, c.g))
			hi = maxf(hi, maxf(c.r, c.g))
	print("[qa] terrain normal rg range=", lo, "..", hi,
		" deviation=", maxf(hi - 0.5, 0.5 - lo), " size=", img.get_size())

func _grid(images: Array[Image], path: String) -> void:
	var half := Vector2i(images[0].get_width() / 2, images[0].get_height() / 2)
	var cols := 2
	var rows := ceili(float(images.size()) / float(cols))
	var sheet := Image.create(half.x * cols, half.y * rows, false, Image.FORMAT_RGBA8)
	for i in images.size():
		var scaled := images[i].duplicate()
		if scaled.get_format() != Image.FORMAT_RGBA8:
			scaled.convert(Image.FORMAT_RGBA8)
		scaled.resize(half.x, half.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(scaled, Rect2i(0, 0, half.x, half.y),
			Vector2i((i % cols) * half.x, (i / cols) * half.y))
	sheet.save_png(path)
