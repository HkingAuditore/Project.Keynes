# 临时实况复现探针（一次性）：复现用户"看不到植被"截图场景。
# 与 soak 探针同一世界（60x40/seed 1），但：
#   1) Camera2D 远焦（对应截图大陆视角）
#   2) 每天 tick 后只泵 1 帧（模拟高速游玩，队列不必然排空）
#   3) day0/day30 截屏 + detail_visibility_probe 转储
# 运行(窗口模式, 勿加 --quit):
#   godot --path Project/project-keynes --script res://tests/_tmp_live_veg_repro.gd
extends SceneTree

const FAR_ZOOM := 0.5
const PLAY_DAYS := 30

func _init() -> void:
	_bootstrap()


func _bootstrap() -> void:
	while get_root() == null or not get_root().is_inside_tree():
		await process_frame
	await process_frame
	var code := await _run()
	quit(code)


func _run() -> int:
	print("[REPRO] ==== live vegetation-visibility repro ====")
	get_root().size = Vector2i(1600, 1000)
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var renderer := HexRenderer.new()
	renderer.visual_quality = 2
	get_root().add_child(renderer)
	await process_frame

	var camera := MapCamera.new()
	get_root().add_child(camera)

	var host := WorldRuntimeHost.new()
	host.generate_test_economy_data = false
	get_root().add_child(host)
	host.configure(renderer, camera, clock)

	Engine.set_meta(WorldRuntimeHost.WORLD_SETUP_META, {
		"source": "world_setup",
		"base": {
			"map_width": 60, "map_height": 40, "initial_seed": 1,
			"sea_level": 0.42, "num_continents": 2, "continent_size": 0.9,
			"generate_test_economy_data": false,
		},
	})
	await host.generate_world(-1)
	Engine.remove_meta(WorldRuntimeHost.WORLD_SETUP_META)

	var world: WorldData = host.world_data()
	if world == null:
		push_error("[REPRO] world missing")
		return 1

	# 独立 Camera2D 接管视野（MapCamera 留给 host 接线），对准世界中心 + 远焦
	var cam := Camera2D.new()
	get_root().add_child(cam)
	var bounds: Rect2 = world.world_bounds
	cam.position = bounds.get_center()
	cam.zoom = Vector2(FAR_ZOOM, FAR_ZOOM)
	cam.make_current()
	renderer.set_camera_zoom(FAR_ZOOM)
	for i in range(15):
		await process_frame

	_dump_vis(renderer, "day0")
	await _shot("D:/Godot/ProjectKeynes/Project.Keynes/tmp/_live_repro_day0.png")

	for day in range(1, PLAY_DAYS + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while clock.has_method("has_hard_barrier") and clock.has_hard_barrier() and pulses < 16:
			clock.simulation_backpressure_pulse.emit(day)
			pulses += 1
		await process_frame

	# 静置 90 帧让队列完全消化
	for i in range(90):
		await process_frame
	_dump_vis(renderer, "day30_settled_far")
	await _shot("D:/Godot/ProjectKeynes/Project.Keynes/tmp/_live_repro_day30_far.png")

	# 拉近焦对比（同一块区域）
	cam.zoom = Vector2(1.2, 1.2)
	renderer.set_camera_zoom(1.2)
	for i in range(10):
		await process_frame
	_dump_vis(renderer, "day30_near")
	await _shot("D:/Godot/ProjectKeynes/Project.Keynes/tmp/_live_repro_day30_near.png")
	print("[REPRO] ==== repro done ====")
	return 0


func _dump_vis(renderer, tag: String) -> void:
	for layer in renderer._detail_layers:
		if layer == null or not layer.has_method("detail_visibility_probe"):
			continue
		var info: Dictionary = layer.detail_visibility_probe()
		print("[REPRO] %s %s visible=%s inst=%d chunk_vis_sum=%s chunks=%s/%s lod_t=%.2f zoom=%.2f far_frac=%s" % [
			tag, layer.name, str(info.get("layer_visible", "?")),
			int(info.get("instance_count", -1)),
			str(info.get("chunk_visible_sum", "?")),
			str(info.get("chunk_nodes_visible", "?")), str(info.get("chunk_nodes", "?")),
			float(info.get("lod_zoom_t", -1.0)), float(info.get("camera_zoom", -1.0)),
			str(info.get("lod_far_visible_fraction", "?")),
		])


func _shot(path: String) -> void:
	await process_frame
	await process_frame
	var img := get_root().get_texture().get_image()
	img.save_png(path)
	print("[REPRO] screenshot -> %s" % path)
