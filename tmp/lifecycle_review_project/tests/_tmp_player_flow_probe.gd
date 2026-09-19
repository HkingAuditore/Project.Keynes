extends Node

# 走正式流程（GameFlowService.begin_new_game → player_game.tscn）启动一局，等世界稳定
# 后连拍几张截图。此前所有"桌面正常"的对照都是直接加载 main.tscn 得到的，而 Web 上的
# 故障发生在正式流程里——两个场景对 HexRenderer 的属性覆盖并不相同，所以那批对照根本
# 没有覆盖出问题的配置。这个探针把桌面也放到正式流程上，用来判定故障到底是不是 Web 独有。
#
# 用法：
#   godot --path Project/project-keynes res://tests/_tmp_player_flow_probe.tscn -- <out.png> [wait_sec]

const SHOT_INTERVAL_FRAMES := 40

# begin_new_game 会 change_scene_to_file，而那会释放 current_scene——也就是这个探针
# 场景自己。所以真正干活的实例必须是挂在 /root 下、但不是 current_scene 的另一个节点。
var _detached: bool = false


func _ready() -> void:
	if not _detached:
		var worker = (get_script() as GDScript).new()
		worker._detached = true
		worker.name = "PlayerFlowProbeWorker"
		get_tree().root.add_child.call_deferred(worker)
		return
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://flow.png"
	var wait_sec: float = float(args[1]) if args.size() > 1 else 45.0

	var flow := get_node_or_null("/root/GameFlow")
	if flow == null:
		print("[flow-probe] GameFlowService autoload missing")
		get_tree().quit(1)
		return

	# 贴着 web 的实际条件：地图尺寸压在 FeatureFlags 的 web 上限之内。
	var config := NewGameConfig.new()
	config.country.name = "Flow Probe"
	config.country.foreign_count = 3
	config.base.map_width = 60
	config.base.map_height = 40
	config.base.initial_seed = 20260805
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8

	var begin: Dictionary = flow.call("begin_new_game", config)
	print("[flow-probe] begin_new_game ok=%s" % str(begin.get("ok", false)))
	if not bool(begin.get("ok", false)):
		print("[flow-probe] ", begin)
		get_tree().quit(1)
		return

	var host := await _wait_for_runtime(wait_sec)
	if host == null:
		print("[flow-probe] runtime host never became ready")
		get_tree().quit(1)
		return
	print("[flow-probe] runtime ready")

	var renderer = host.get("_renderer")
	_report_renderer(renderer)

	# 连拍：故障若在 tick 之间翻转，多张之间就会出现差异。
	for shot in range(4):
		for _i in range(SHOT_INTERVAL_FRAMES):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null:
			print("[flow-probe] shot ", shot, " viewport image null")
			continue
		var path := out_path.replace(".png", "_%d.png" % shot)
		img.save_png(path)
		print("[flow-probe] shot ", shot, " -> ", path, " ", _describe(img))

	print("[flow-probe] DONE")
	get_tree().quit()


func _wait_for_runtime(wait_sec: float) -> Node:
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < wait_sec:
		await get_tree().process_frame
		var scene := get_tree().current_scene
		if scene == null:
			continue
		var host := _find_host(scene)
		if host != null and host.get("_renderer") != null:
			# 世界就绪后再多等一会，让首日仿真与 LUT 日刷都跑起来。
			for _i in range(120):
				await get_tree().process_frame
			return host
	return null


func _find_host(node: Node) -> Node:
	if node is WorldRuntimeHost:
		return node
	for child in node.get_children():
		var found := _find_host(child)
		if found != null:
			return found
	return null


func _report_renderer(renderer) -> void:
	if renderer == null:
		print("[flow-probe] renderer unavailable")
		return
	print("[flow-probe] horizon: strength=%.2f softness=%.2f max_angle=%.4f cast_floor=%.2f" % [
		renderer.terrain_horizon_strength, renderer.terrain_horizon_softness,
		renderer.terrain_horizon_max_angle, renderer.terrain_horizon_cast_floor])
	print("[flow-probe] gi: ao=%.2f floor=%.2f bent=%.2f bounce=%.2f" % [
		renderer.gi_ao_strength, renderer.gi_ao_floor,
		renderer.gi_bent_strength, renderer.gi_bounce_strength])
	print("[flow-probe] quality=%d materials=%s debug_view=%d" % [
		renderer.visual_quality, str(renderer.terrain_materials_enabled),
		renderer.terrain_surface_debug_view])
	var world = renderer.get("_world")
	if world != null:
		print("[flow-probe] world: lut_dims=%s horizon_tex=%s enum_lut=%s" % [
			str(world.lut_dims), str(world.terrain_horizon_tex != null),
			str(world.enum_lut_tex != null)])


func _describe(img: Image) -> String:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, mini(w, h) / 96)
	var total := 0
	var blue_dom := 0
	var green_dom := 0
	var sum_r := 0.0
	var sum_g := 0.0
	var sum_b := 0.0
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
	if total == 0:
		return "empty"
	return "mean_rgb=(%.3f,%.3f,%.3f) blue_dom=%.1f%% green_dom=%.1f%%" % [
		sum_r / total, sum_g / total, sum_b / total,
		100.0 * float(blue_dom) / float(total),
		100.0 * float(green_dom) / float(total),
	]
