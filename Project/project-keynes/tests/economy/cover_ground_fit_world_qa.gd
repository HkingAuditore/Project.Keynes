extends SceneTree

# [cover-ground-fit 2026-11-18] 植物群落地被（ResourceGroundCover）的 A/B。
#
# 相机对准一块真有作物群落的陆地格，只改 cover_ground_tint：
#   A before   tint=0      → 回到固定的 cover_saturation/gain/grade 全局调色
#   B tint     tint=0.35   → 群落色温向脚下 hypsometric 地表色靠拢
#   C wide     tint=0.35   → 同一格但拉远，检查远景是否仍然连片
#
# 出图：tmp/cover_ground_fit_qa/cover_ab.png（三行竖排）
# 这是 QA 夹具，不写 PASS/FAIL。

const ResourceCatalog = preload("res://scripts/rendering/resource_visual_catalog.gd")

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
		push_error("cover QA timed out")
		quit(1)
		return
	var game := current_scene
	game.get_node("WorldClock").pause(true)
	game.get_node("UI").visible = false
	var renderer := host.get_renderer()
	renderer.set_day_night_enabled(false)
	host.set_fog_of_war_enabled(false)
	var layer = renderer._resource_visual_layer
	if layer == null or layer.ground_cover() == null:
		push_error("ground cover missing")
		quit(1)
		return
	var cover_mat: ShaderMaterial = layer.ground_cover().material()
	# prepare_frame 里 `_cover.set_enabled(... and _context_ready)`，而 _context_ready
	# 只在 set_context() 里置位。正式流程由会话层调用；QA 必须自己补，否则地被层
	# 全程 visible=false，改什么参数都看不出差别。
	layer.set_context(false, 0)
	cover_mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	cover_mat.set_shader_parameter("tod_sun_dir", Vector3(0.62, -0.42, 0.40).normalized())
	var map := host.current_map()
	var camera := game.get_node("MapCamera") as Camera2D
	# 相机位置有外部约束（会话层每帧把镜头钉在某个锚点），QA 移动它会被拉回。
	# 所以不移动相机：先把 zoom 压到目标档，读它稳定后的中心，再在**当前视野内**
	# 挑一块作物格。这样无论镜头被钉在哪都能拍到。
	camera.set("_qa_zoom", 0.0)
	camera.set("_qa_zoom_until_ms", 0)
	camera.zoom = Vector2(6.0, 6.0)
	camera.set("_target_zoom", Vector2(6.0, 6.0))
	for frame in 30:
		await process_frame
	var view_center := camera.position
	var half := Vector2(root.size) / (2.0 * maxf(camera.zoom.x, 0.01)) * 0.55
	var cell := _pick_plant_cell(map, view_center, half)
	var point := Vector2(map.cell_pos_x_arr[cell], map.cell_pos_y_arr[cell]) * renderer.hex_size
	print("[qa] view_center=", view_center, " half=", half,
		" plant cell=", cell, " point=", point,
		" vitality=", map.vegetation_vitality_arr[cell],
		" cover_tint=", cover_mat.get_shader_parameter("cover_ground_tint"),
		" cover_opacity=", cover_mat.get_shader_parameter("cover_opacity"),
		" clump=", cover_mat.get_shader_parameter("clump_strength"))
	var output := "res://tmp/cover_ground_fit_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var shots: Array[Image] = []
	for variant in [["A_before", 0.0, 6.0], ["B_tint", 0.5, 6.0], ["C_wide", 0.5, 1.6]]:
		cover_mat.set_shader_parameter("cover_ground_tint", float(variant[1]))
		var z := float(variant[2])
		camera.zoom = Vector2(z, z)
		camera.set("_target_zoom", Vector2(z, z))
		for frame in 90:
			camera.zoom = Vector2(z, z)
			camera.set("_target_zoom", Vector2(z, z))
			await process_frame
		print("[qa] ", variant[0], " cam_pos=", camera.position, " cam_zoom=", camera.zoom,
			" bounds=", camera.get("_world_bounds"))
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.save_png(output + "/cover_" + String(variant[0]) + ".png")
		shots.append(image)
	_sheet(shots, output + "/cover_ab.png")
	print("cover ground fit QA: ", output, "/cover_ab.png")
	quit(0)

## 优先找真有作物占用位的陆地格（小麦/玉米等），并在其中挑离陆地质心最近的 ——
## 边角小岛上的群落看不到"连片/碎斑"的差别。找不到作物时退回活力最高的陆地格。
func _pick_plant_cell(map, view_center: Vector2, half: Vector2) -> int:
	var bits := PackedInt64Array()
	for entry in ResourceCatalog.entries():
		if String(entry.id) in ["bio.wheat", "bio.maize", "bio.rice", "bio.cotton", "bio.potato"]:
			var bit := int(entry.bit)
			if bit >= 0:
				bits.append(bit)
	var best := -1
	var best_d := INF
	for c in map.cell_count():
		if map.is_water_arr[c] != 0:
			continue
		var p := Vector2(map.cell_pos_x_arr[c], map.cell_pos_y_arr[c]) * 22.0
		if absf(p.x - view_center.x) > half.x or absf(p.y - view_center.y) > half.y:
			continue
		var occ := int(map.bio_occupancy_bits_arr[c])
		var hit := bits.is_empty()
		for bit in bits:
			if (occ & (1 << bit)) != 0:
				hit = true
				break
		if not hit:
			continue
		var d := p.distance_squared_to(view_center)
		if d < best_d:
			best_d = d
			best = c
	if best >= 0:
		return best
	# 视野内没有作物：退到视野内活力最高的陆地格。
	var best_v := -1.0
	for c in map.cell_count():
		if map.is_water_arr[c] != 0:
			continue
		var p := Vector2(map.cell_pos_x_arr[c], map.cell_pos_y_arr[c]) * 22.0
		if absf(p.x - view_center.x) > half.x or absf(p.y - view_center.y) > half.y:
			continue
		var v := float(map.vegetation_vitality_arr[c])
		if v > best_v:
			best_v = v
			best = c
	return maxi(best, 0)

func _sheet(images: Array[Image], path: String) -> void:
	var w := images[0].get_width()
	var h := images[0].get_height()
	var sheet := Image.create(w, h * images.size(), false, Image.FORMAT_RGBA8)
	for i in images.size():
		var src := images[i]
		if src.get_format() != Image.FORMAT_RGBA8:
			src = src.duplicate()
			src.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(src, Rect2i(0, 0, w, h), Vector2i(0, i * h))
	sheet.save_png(path)
