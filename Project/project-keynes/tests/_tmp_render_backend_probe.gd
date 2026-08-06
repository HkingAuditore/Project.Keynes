extends Node

# 在当前渲染后端下加载 main.tscn（会在 _ready 里自动生成并渲染世界），
# 等世界稳定后抓一张视口截图。用于 Forward+ 与 Compatibility 的逐像素对比：
# 判断"整图变蓝"到底是 Web 独有，还是 Compatibility 后端就能复现。
#
# 用法：
#   godot --path Project/project-keynes res://tmp/render_backend_probe.tscn -- <out.png> [wait_sec]

const MAIN_SCENE := "res://scenes/main.tscn"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://probe.png"
	var wait_sec: float = float(args[1]) if args.size() > 1 else 25.0

	print("[backend-probe] driver=", RenderingServer.get_video_adapter_api_version(),
		" adapter=", RenderingServer.get_video_adapter_name())

	var scene := load(MAIN_SCENE)
	if scene == null:
		print("[backend-probe] FAILED to load ", MAIN_SCENE)
		get_tree().quit(1)
		return
	var inst: Node = scene.instantiate()
	get_tree().root.add_child.call_deferred(inst)
	await get_tree().process_frame
	await get_tree().process_frame

	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < wait_sec:
		await get_tree().process_frame

	var mat: ShaderMaterial = _terrain_material(inst)
	if mat != null:
		print("[backend-probe] lut_dims=", mat.get_shader_parameter("lut_dims"),
			" map_index_atlas=", mat.get_shader_parameter("map_index_atlas"))
		_report_samplers(inst, mat)

	if mat != null:
		var flow_tex: Texture2D = mat.get_shader_parameter("flow_tex")
		print("[backend-probe] flow_tex=", flow_tex != null,
			" size=", flow_tex.get_size() if flow_tex != null else "-",
			" format=", flow_tex.get_format() if flow_tex != null else "-",
			" has_flow_tex=", mat.get_shader_parameter("has_flow_tex"))
		print("[backend-probe] flow_encode=", DCAtlasEncoders.last_flow_encode_info)

	# shot 0 = 原样；1 = 陆/水分支；2 = 光照前底色；3 = 河流层之前的静态底色；4 = flow。
	const VIEWS := [0, 14, 16, 17]
	var renderer = inst.get("_renderer")
	for shot in range(VIEWS.size()):
		if renderer != null:
			renderer.terrain_surface_debug_view = VIEWS[shot]
		for _i in range(20):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null:
			print("[backend-probe] shot ", shot, " viewport image null")
			continue
		var path := out_path.replace(".png", "_%d.png" % shot)
		var err := img.save_png(path)
		print("[backend-probe] shot ", shot, " -> ", path, " err=", err,
			" size=", img.get_size(), " ", _describe(img))

	print("[backend-probe] DONE")
	get_tree().quit()


# WebGL2 只保证 16 个片元纹理单元，桌面 GL 给 32。落在两者之间的 sampler 数量
# 只会在 Web 上出问题，所以这里把每个材质实际声明的 sampler 数与绑定状态列全。
func _report_samplers(main: Node, terrain: ShaderMaterial) -> void:
	var renderer = main.get("_renderer")
	var targets: Array = [["terrain", terrain]]
	for prop in ["_weather_layer", "_fog_layer", "_border_layer"]:
		var layer = renderer.get(prop)
		if layer != null:
			for child in _walk(layer):
				var m = child.get("material") if "material" in child else null
				if m is ShaderMaterial:
					targets.append([prop + "/" + child.name, m])
	for entry in targets:
		var label: String = entry[0]
		var mat: ShaderMaterial = entry[1]
		if mat == null or mat.shader == null:
			continue
		var bound: Array[String] = []
		var unbound: Array[String] = []
		for u in mat.shader.get_shader_uniform_list():
			if int(u.get("type", 0)) != TYPE_OBJECT:
				continue
			if not String(u.get("hint_string", "")).contains("Texture"):
				continue
			var name := String(u.get("name", ""))
			if mat.get_shader_parameter(name) == null:
				unbound.append(name)
			else:
				bound.append(name)
		print("[backend-probe][samplers] %s total=%d bound=%d unbound=%s"
			% [label, bound.size() + unbound.size(), bound.size(), str(unbound)])


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out


func _terrain_material(main: Node) -> ShaderMaterial:
	var renderer = main.get("_renderer")
	if renderer == null:
		print("[backend-probe] renderer unavailable")
		return null
	return renderer.get("_shader_mat") as ShaderMaterial


# 粗略统计画面色调：蓝色主导的像素占比，用来在不看图的情况下判断是否"整图变蓝"。
func _describe(img: Image) -> String:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, mini(w, h) / 96)
	var total := 0
	var blue_dom := 0
	var green_dom := 0
	var black := 0
	var sum_r := 0.0
	var sum_g := 0.0
	var sum_b := 0.0
	# 调试档判读靠"画面里有多少种颜色"：塌缩成常量时桶数会掉到个位数。
	var buckets := {}
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			total += 1
			sum_r += c.r
			sum_g += c.g
			sum_b += c.b
			if c.b > c.r + 0.04 and c.b > c.g + 0.02:
				blue_dom += 1
			elif c.g > c.r + 0.03 and c.g > c.b + 0.03:
				green_dom += 1
			if c.r < 0.02 and c.g < 0.02 and c.b < 0.02:
				black += 1
			buckets[Vector3i(int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0))] = true
	if total == 0:
		return "empty"
	return "mean_rgb=(%.3f,%.3f,%.3f) blue_dom=%.1f%% green_dom=%.1f%% black=%.1f%% colors=%d" % [
		sum_r / total, sum_g / total, sum_b / total,
		100.0 * float(blue_dom) / float(total),
		100.0 * float(green_dom) / float(total),
		100.0 * float(black) / float(total),
		buckets.size(),
	]
