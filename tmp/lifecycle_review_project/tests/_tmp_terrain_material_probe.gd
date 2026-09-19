extends SceneTree

# [terrain-material-tiles] 运行时诊断探针（一次性工具，勿长期保留）。
# 以真实窗口模式运行（GPU 真编译 shader），复现玩家世界生成链路，然后：
#   1) dump 四个 shader 门禁的运行时实际值
#   2) dump 编译后 shader 的 uniform 列表中 terrain_material_* 是否存在
#   3) A/B 抓图：材质路径强制 ON（强度放大）vs 强制 OFF，比较像素差异
# 输出统一用 [PROBE] 前缀，退出码恒 0。

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")


func _init() -> void:
	_bootstrap()


func _bootstrap() -> void:
	# SceneTree._init 里 root Window 可能尚未 enter tree：此时 add_child 不会
	# 触发 _ready（探针前几次运行因此拿到半个残废渲染器，结论全部作废）。
	# 等到 root 确认在树内再开始。
	while get_root() == null or not get_root().is_inside_tree():
		await process_frame
	await process_frame
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	print("[PROBE] ==== terrain material runtime probe ====")
	print("[PROBE] root inside tree: %s" % str(get_root().is_inside_tree()))
	print("[PROBE] rendering_method=%s" % (
		RenderingServer.get_current_rendering_method()
		if RenderingServer.has_method("get_current_rendering_method") else "<no-api>"))
	print("[PROBE] DCWorldExt=%s" % str(ClassDB.class_exists("DCWorldExt")))

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var renderer := HexRenderer.new()
	renderer.visual_quality = 2
	renderer.terrain_materials_enabled = true
	get_root().add_child(renderer)
	await process_frame
	print("[PROBE] renderer ready check: inside_tree=%s world_quad=%s shader_mat=%s" % [
		str(renderer.is_inside_tree()),
		str(renderer._world_quad != null),
		str(renderer._shader_mat != null)])

	var camera := MapCamera.new()
	get_root().add_child(camera)

	var host := WorldRuntimeHost.new()
	host.generate_test_economy_data = false
	get_root().add_child(host)
	host.configure(renderer, camera, clock)

	# 复现玩家持久化启动配置（含 render_quality_mode=2 与地图尺寸）。
	var saved_setup := _load_saved_world_setup()
	if saved_setup.is_empty():
		print("[PROBE] WARN: no saved world setup; using host defaults")
	else:
		Engine.set_meta(WorldRuntimeHost.WORLD_SETUP_META, saved_setup)

	await host.generate_world(-1)
	if not saved_setup.is_empty():
		Engine.remove_meta(WorldRuntimeHost.WORLD_SETUP_META)

	var world: WorldData = host.world_data()
	if world == null:
		push_error("[PROBE] world_data is null after generation")
		return 1

	renderer.set_visual_quality(2)
	if renderer.has_method("set_terrain_materials_enabled"):
		renderer.set_terrain_materials_enabled(true)
	if renderer.has_method("set_day_night_enabled"):
		renderer.set_day_night_enabled(false)
		print("[PROBE] day_night disabled on renderer")
	_hide_fog(renderer)
	print("[PROBE] renderer inside_tree=%s" % str(renderer.is_inside_tree()))
	var found_renderers := get_root().find_children("*", "HexRenderer", true, false)
	print("[PROBE] HexRenderer nodes in tree: %d" % found_renderers.size())
	for n in found_renderers:
		print("[PROBE]   -> %s (script=%s)" % [str(n.get_path()), str(n.get_script().resource_path if n.get_script() != null else "null")])
	print("[PROBE] root children:")
	for c in get_root().get_children():
		print("[PROBE]   %s type=%s kids=%d script=%s" % [
			c.name, c.get_class(), c.get_child_count(),
			str(c.get_script().resource_path if c.get_script() != null else "null")])
	print("[PROBE] renderer path=%s" % (str(renderer.get_path()) if renderer.is_inside_tree() else "<not-in-tree>"))
	var wq: MeshInstance2D = renderer._world_quad
	print("[PROBE] _world_quad path=%s visible=%s z=%d pos=%s top_level=%s" % [
		wq.get_path(), str(wq.visible), wq.z_index, str(wq.global_position), str(wq.top_level)])
	print("[PROBE] _world_quad mesh=%s surfaces=%d" % [
		str(wq.mesh), wq.mesh.get_surface_count() if wq.mesh != null else -1])
	print("[PROBE] _world_quad material==_shader_mat: %s" % str(wq.material == renderer._shader_mat))
	_dump_tree(get_root())

	# 相机取景整幅世界，保证抓图可读。
	var vp_size := get_root().get_visible_rect().size
	var bounds: Rect2 = world.world_bounds
	camera.global_position = bounds.get_center()
	var fit := minf(vp_size.x / maxf(bounds.size.x, 1.0), vp_size.y / maxf(bounds.size.y, 1.0))
	camera.zoom = Vector2(fit, fit) * 0.98
	camera.make_current()

	await _settle_frames(4)

	# ─── ① GDScript 侧门禁实际值 ─────────────────────────────────────────
	print("[PROBE] world.terrain_material_tex!=null: %s" % str(world.terrain_material_tex != null))
	if world.terrain_material_tex != null:
		print("[PROBE] world.terrain_material_tex.layers=%d" % world.terrain_material_tex.get_layers())
	print("[PROBE] world.terrain_material_tex_bound: %s" % str(world.terrain_material_tex_bound))
	print("[PROBE] baker shared error(1024): '%s'" % MapBakerScript.shared_terrain_material_error(1024))
	print("[PROBE] renderer.visual_quality=%d terrain_materials_enabled=%s" % [
		renderer.visual_quality, str(renderer.terrain_materials_enabled)])

	var mat: ShaderMaterial = renderer._shader_mat
	if mat == null or mat.shader == null:
		push_error("[PROBE] renderer shader material missing")
		return 1

	# 探针世界是全新未探索地图：fog_k=0 会让主 shader 走迷雾早退/灰化分支，
	# 土地管线根本不执行，A/B 必然无差异。这里把迷雾从主 shader 里彻底关掉。
	mat.set_shader_parameter("fog_gray_enabled", false)
	mat.set_shader_parameter("fog_gray_strength", 0.0)
	mat.set_shader_parameter("fog_early_out_enabled", false)
	print("[PROBE] fog params forced off: gray=%s strength=%s early_out=%s" % [
		str(mat.get_shader_parameter("fog_gray_enabled")),
		str(mat.get_shader_parameter("fog_gray_strength")),
		str(mat.get_shader_parameter("fog_early_out_enabled"))])

	# ─── ② 材质 uniform 回读 ─────────────────────────────────────────────
	print("[PROBE] mat.param terrain_material_tex!=null: %s" % str(
		mat.get_shader_parameter("terrain_material_tex") != null))
	print("[PROBE] mat.param terrain_material_tex_bound: %s" % str(
		mat.get_shader_parameter("terrain_material_tex_bound")))
	print("[PROBE] mat.param terrain_materials_enabled: %s" % str(
		mat.get_shader_parameter("terrain_materials_enabled")))
	print("[PROBE] mat.param visual_quality: %s" % str(mat.get_shader_parameter("visual_quality")))

	# ─── ③ 编译期证据：shader 资源是否包含新代码 ────────────────────────
	print("[PROBE] shader.code has touch comment: %s" % str(
		mat.shader.code.contains("terrain-material-tiles 2026-08-01")))
	if mat.shader.has_method("get_shader_uniform_list"):
		var found: Array[String] = []
		for entry in mat.shader.get_shader_uniform_list():
			var uname := String(entry.get("name", ""))
			if uname.contains("terrain_material"):
				found.append(uname)
		print("[PROBE] shader uniform list terrain_material_*: %s" % str(found))
	else:
		print("[PROBE] get_shader_uniform_list unavailable")

	var gate := bool(mat.get_shader_parameter("terrain_materials_enabled")) \
		and bool(mat.get_shader_parameter("terrain_material_tex_bound")) \
		and int(mat.get_shader_parameter("visual_quality")) >= 2
	print("[PROBE] shader-side gate (enabled && bound && q>=2): %s" % str(gate))

	# ─── ④ A/B 像素证据：强制 ON(放大) vs 强制 OFF ──────────────────────
	mat.set_shader_parameter("terrain_material_albedo_strength", 1.0)
	mat.set_shader_parameter("terrain_material_normal_strength", 0.35)
	await _settle_frames(3)
	var img_on := await _capture("probe_on_boost")

	mat.set_shader_parameter("terrain_materials_enabled", false)
	await _settle_frames(3)
	var img_off := await _capture("probe_off")

	if img_on != null and img_off != null:
		var diff := _mean_abs_diff(img_on, img_off)
		print("[PROBE] A/B mean|diff| per channel: %s" % diff)
		print("[PROBE] A/B verdict: %s" % (
			"PIXELS DIFFER -> material path IS compiled into the shader"
			if diff > 0.002 else
			"PIXELS IDENTICAL -> material branch is dead (shader stale or branch eliminated)"))

	# ─── ⑤ debug_view=7：直读活 shader 的门禁 ───────────────────────────
	# 绿=ACTIVE / 蓝=tex 未绑定 / 品红=enabled=false / 橙=quality<2或分支被裁剪。
	# 若抓图仍是正常地形而非纯色 → terrain_surface_debug_view 没到达屏幕，
	# 即 _shader_mat 根本没在驱动屏幕上的地形。
	mat.set_shader_parameter("terrain_materials_enabled", true)
	mat.set_shader_parameter("terrain_material_albedo_strength", 0.22)
	mat.set_shader_parameter("terrain_material_normal_strength", 0.045)
	mat.set_shader_parameter("terrain_surface_debug_view", 7)
	await _settle_frames(3)
	var img_dv := await _capture("probe_dv7_gate")
	if img_dv != null:
		print("[PROBE] dv7 pixel classes: %s" % _classify_gate_pixels(img_dv))
	mat.set_shader_parameter("terrain_surface_debug_view", 0)

	# ─── ⑥ 默认强度 + 战斗缩放 A/B：模拟玩家实际缩放级别下的可见性 ─────
	mat.set_shader_parameter("terrain_materials_enabled", true)
	mat.set_shader_parameter("terrain_material_albedo_strength", 0.22)
	mat.set_shader_parameter("terrain_material_normal_strength", 0.045)
	mat.set_shader_parameter("terrain_material_roughness_strength", 0.35)
	# 取景一块陆地区域，zoom≈0.35（玩家看定居点的典型级别）。
	var focus := bounds.get_center()
	focus.y = bounds.position.y + bounds.size.y * 0.45
	camera.global_position = focus
	camera.zoom = Vector2(0.35, 0.35)
	await _settle_frames(4)
	var img_don := await _capture("probe_default_on_zoomin")
	mat.set_shader_parameter("terrain_materials_enabled", false)
	await _settle_frames(3)
	var img_doff := await _capture("probe_default_off_zoomin")
	if img_don != null and img_doff != null:
		var ddiff := _mean_abs_diff(img_don, img_doff)
		print("[PROBE] default-strength zoomed-in A/B mean|diff|: %s" % ddiff)
	mat.set_shader_parameter("terrain_materials_enabled", true)

	print("[PROBE] ==== probe done ====")
	return 0


func _classify_gate_pixels(img: Image) -> Dictionary:
	# 按色相分类（容许夜间调光导致的整体变暗）。
	var counts := {"green": 0, "orange": 0, "blue": 0, "magenta": 0, "other": 0}
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(sqrt(float(w * h) / 60000.0)))
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			var mx := maxf(c.r, maxf(c.g, c.b))
			if mx < 0.05:
				counts["other"] += 1
			elif c.g > c.r * 1.35 and c.g > c.b * 1.35:
				counts["green"] += 1
			elif c.r > c.b * 2.0 and c.g > c.b * 1.6 and c.r > c.g * 1.3:
				counts["orange"] += 1
			elif c.b > c.r * 1.6 and c.b > c.g * 1.6:
				counts["blue"] += 1
			elif c.r > c.g * 1.6 and c.b > c.g * 1.6:
				counts["magenta"] += 1
			else:
				counts["other"] += 1
	return counts


func _dump_tree(node: Node, indent := "") -> void:
	var desc := "%s%s (%s)" % [indent, node.name, node.get_class()]
	if node is CanvasItem:
		var ci := node as CanvasItem
		desc += " z=%d visible=%s" % [ci.z_index, str(ci.visible)]
		if node is MeshInstance2D:
			var mi := node as MeshInstance2D
			desc += " pos=%s mesh_surfaces=%d" % [
				str(mi.global_position),
				mi.mesh.get_surface_count() if mi.mesh != null else -1]
			if mi.material is ShaderMaterial:
				var sm := mi.material as ShaderMaterial
				desc += " dv=%s tm_bound=%s tm_tex=%s" % [
					str(sm.get_shader_parameter("terrain_surface_debug_view")),
					str(sm.get_shader_parameter("terrain_material_tex_bound")),
					str(sm.get_shader_parameter("terrain_material_tex") != null)]
	print("[PROBE][TREE] " + desc)
	for child in node.get_children():
		_dump_tree(child, indent + "  ")


func _settle_frames(n: int) -> void:
	for i in range(n):
		await process_frame
	await RenderingServer.frame_post_draw


func _capture(label: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	if img == null or img.is_empty():
		print("[PROBE] capture %s failed" % label)
		return null
	var path := "user://%s.png" % label
	img.save_png(path)
	print("[PROBE] captured %s -> %s" % [label, ProjectSettings.globalize_path(path)])
	return img


func _mean_abs_diff(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return -1.0
	var w := a.get_width()
	var h := a.get_height()
	var step := maxi(1, int(sqrt(float(w * h) / 40000.0)))
	var sum := 0.0
	var count := 0
	for y in range(0, h, step):
		for x in range(0, w, step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			count += 3
	return sum / maxf(float(count), 1.0)


func _hide_fog(renderer: HexRenderer) -> void:
	if renderer.has_method("set_fog_enabled"):
		renderer.set_fog_enabled(false)
	for child in renderer.get_children():
		if child is CanvasItem and String(child.name).to_lower().contains("fog"):
			(child as CanvasItem).visible = false


func _load_saved_world_setup() -> Dictionary:
	var path := "user://world_setup_settings.json"
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and String((parsed as Dictionary).get("source", "")) == "world_setup":
		return parsed as Dictionary
	return {}
