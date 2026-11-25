extends SceneTree

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("Land cache readback requires a rendering device")
		quit()
		return
	if not root.is_node_ready():
		await root.ready
	await process_frame
	var settings := root.get_node("GameSettings")
	settings.update({"render_quality": "high", "window_mode": "windowed",
		"resolution_width": 1600, "resolution_height": 960, "ui_layout_scale": 125}, false)
	var config := NewGameConfig.create_default()
	config.base.initial_seed = 20260718
	config.base.map_width = 60
	config.base.map_height = 40
	config.country.foreign_count = 3
	root.get_node("GameFlow").set("_pending_request", {"kind": "new_game", "config": config.to_dictionary()})
	var game := preload("res://scenes/player_game.tscn").instantiate()
	var host := game.get_node("RuntimeHost") as WorldRuntimeHost
	host.world_generation_failed.connect(func(reason: String):
		push_error(reason)
		quit(2)
	)
	root.add_child(game)
	await host.world_ready
	var loading := game.get_node("UI/UIRoot/ModalLayer/WorldLoadingOverlay") as Control
	while loading.visible:
		await loading.visibility_changed
	var land := game.get_node("%WorldRoot/HexRenderer") as HexRenderer
	var camera := game.get_node("MapCamera") as MapCamera
	var cache := land._land_base_cache
	game.get_node("WorldClock").pause(true)
	game.get_node("UI").hide()
	land.set_fog_of_war_enabled(false, false)
	# The cache must not stop the independent animation clocks.
	game.get_node("WorldClock").pause(false)
	var water_time := land._world_time
	var fog_time := land.fog_of_war_layer()._world_time
	land.set_fog_of_war_enabled(true, false)
	await _drawable_frame()
	await _drawable_frame()
	_check(land._world_time > water_time and land.fog_of_war_layer()._world_time > fog_time,
		"water and fog animation clocks advance with caching enabled")
	game.get_node("WorldClock").pause(true)
	land.set_fog_of_war_enabled(false, false)
	var map := host.current_map()
	var index := map.is_water_arr.find(0, map.cell_count() / 2)
	_check(index >= 0, "fixture has land")
	if index < 0:
		quit(1)
		return
	var center := Vector2(map.cell_pos_x_arr[index], map.cell_pos_y_arr[index]) * host.hex_size
	camera.restore_view_state(center, Vector2.ONE * 2.25)
	camera.force_update_scroll()
	# Stop time, scatter and camera updates between readbacks. Pre-draw still runs.
	for node in game.find_children("*", "Node", true, false):
		node.process_mode = Node.PROCESS_MODE_DISABLED
	game.process_mode = Node.PROCESS_MODE_DISABLED
	for scale_percent in [100, 75, 100]:
		land.set_terrain_render_scale(scale_percent, Viewport.MSAA_DISABLED)
		await _drawable_frame()
		await _drawable_frame()
		var builds := cache.builds
		land.set_day_phase(0.27)
		await _drawable_frame()
		_check(cache.builds == builds and land._shader_mat.shader == cache._reader and cache._reader != null,
			"stationary land survives lighting updates at %d%%" % scale_percent)
		land.biome_tint_strength = 0.5 if land.biome_tint_strength != 0.5 else 0.6
		await _drawable_frame()
		_check(cache.builds == builds + 1, "changed land colours refresh before display")
		await _check_cached_pixels(cache)
		var revision := land._world.land_base_revision
		map.fog_k_arr[index] = 255 - map.fog_k_arr[index]
		map.vision_revision += 1
		host._republish_cell_luts(PackedInt32Array([index]))
		await _drawable_frame()
		_check(land._world.land_base_revision > revision and land._shader_mat.shader != cache._reader,
			"republished terrain is drawn directly on the first changed frame")
		await _drawable_frame()
		_check(land._shader_mat.shader == cache._reader, "the new publication is reusable next frame")
		camera.restore_view_state(camera.position + Vector2(24, 12), camera.zoom)
		camera.force_update_scroll()
		await _drawable_frame()
		_check(land._shader_mat.shader != cache._reader, "a moved view draws fresh terrain")
	# At 1600x960, fill alone has unit stretch. The explicit 125% UI
	# setting exercises canvas stretching on the native output grid.
	DCFeatureFlags._debug_render_flag("render_viewport")
	DCFeatureFlags._debug_render_flags["render_viewport"] = 0
	settings.ui_scaling().set_qa_override({"profile": "mobile", "layout": "fill"})
	await _drawable_frame()
	await _drawable_frame()
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		and not root.get_stretch_transform().get_scale().is_equal_approx(Vector2.ONE),
		"touch layout exercises a non-unit canvas stretch")
	var output_size := root.get_texture().get_image().get_size()
	_check(cache._views[0].size == output_size and cache._views[1].size == output_size,
		"land cache matches actual pixels in a stretched native-size window")
	_check(cache._reader != null and land._shader_mat.shader == cache._reader,
		"stretched native-size land draws with the cache")
	await _check_cached_pixels(cache)
	settings.ui_scaling().clear_qa_override()
	await _check_idle_presentation(game, land, camera)
	game.queue_free()
	await process_frame
	print("Land base cache: %d failures" % failures)
	quit(int(failures != 0))


func _check_cached_pixels(cache: Node) -> void:
	var cached := root.get_texture().get_image()
	cache.enabled = false
	await _drawable_frame()
	var direct := root.get_texture().get_image()
	var mean_error := 0.0
	var count := 0
	for y in range(0, direct.get_height(), 9):
		for x in range(0, direct.get_width(), 9):
			var a := cached.get_pixel(x, y)
			var b := direct.get_pixel(x, y)
			mean_error += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
			count += 3
	_check(mean_error / count < 1.0 / 255.0, "cached pixels match the direct land material")
	cache.enabled = true
	await _drawable_frame()
	await _drawable_frame()


func _check_idle_presentation(game: Node, land: HexRenderer, camera: MapCamera) -> void:
	var fog := land.fog_of_war_layer()
	land.set_fog_of_war_enabled(true, false)
	fog.set_render_scale(50)
	await _drawable_frame()
	var updates := 0
	for frame in 12:
		var previous: float = fog._shader_mat.get_shader_parameter("world_time")
		fog._process(1.0 / 30.0)
		await _drawable_frame()
		updates += int(previous != fog._shader_mat.get_shader_parameter("world_time"))
	_check(updates == 6, "idle fog redraws six times in twelve display frames")
	fog._process(1.0 / 30.0)
	camera.restore_view_state(camera.position + Vector2(80, 24), camera.zoom)
	camera.force_update_scroll()
	await _drawable_frame()
	_check(is_equal_approx(fog._shader_mat.get_shader_parameter("world_time"), fog._world_time),
		"moving the camera refreshes fog on the first draw")

	var ui := game.get_node("UI") as GameUIManager
	var loading := ui.get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as ColorRect
	ui.show()
	loading.show()
	land.set_terrain_render_scale(75, Viewport.MSAA_DISABLED)
	await _drawable_frame()
	var terrain := land._world_quad.get_viewport() as SubViewport
	_check(not land.is_visible_in_tree() and terrain.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"an opaque full-window loading page skips the world and its scaled terrain")
	ui.hide()
	await _drawable_frame()
	_check(land.is_visible_in_tree(), "a hidden UI layer cannot cover the map")
	ui.show()
	loading.modulate.a = 0.8
	await _drawable_frame()
	_check(land.is_visible_in_tree() and terrain.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"the first translucent draw restores the scaled terrain")
	loading.modulate.a = 1.0
	loading.offset_left += 24.0
	await _drawable_frame()
	_check(land.is_visible_in_tree(), "a visible strip at the edge keeps the map live")
	loading.hide()


# A minimized Metal window can signal frame_post_draw for resource work without drawing.
func _drawable_frame() -> void:
	await RenderingServer.frame_post_draw
	while not DisplayServer.window_can_draw():
		await RenderingServer.frame_post_draw


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
