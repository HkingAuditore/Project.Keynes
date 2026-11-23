extends RefCounted

const WARMUP_FRAMES := 60
const SAMPLE_FRAMES := 240


static func open_game(tree: SceneTree, config: NewGameConfig) -> PlayerGame:
	var flow := tree.root.get_node("GameFlow")
	var started: Dictionary = flow.begin_new_game(config)
	if not bool(started.ok):
		push_error("Could not start the player scene: %s" % str(started))
		return null
	while not tree.current_scene is PlayerGame and flow._transition_active:
		await tree.process_frame
	var game := tree.current_scene as PlayerGame
	if game == null:
		push_error("The game flow did not open the player scene.")
		return null
	# Freeze the calendar before PlayerGame starts generation. The explored
	# fixture can still admit its two explicit days through the runtime host.
	game._world_clock.pause(true)
	var host := game._runtime_host
	if host.session_config().is_empty():
		return null
	while not host.is_runtime_ready_for_ticks() and host.last_world_generation_error.is_empty():
		await tree.process_frame
	if not host.is_runtime_ready_for_ticks():
		push_error(host.last_world_generation_error_text())
		return null
	var loading := game.get_node("UI/UIRoot/ModalLayer/WorldLoadingOverlay") as Control
	while loading.visible:
		await loading.visibility_changed
	host.fit_camera()
	return game


static func _summary(values: Array) -> Dictionary:
	if values.is_empty():
		return {"samples": 0, "mean": null, "median": null, "p95": null}
	var sorted := values.duplicate()
	sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for sample in sorted:
		total += sample
	var middle := count >> 1
	var median: float = (sorted[middle - 1] + sorted[middle]) / 2.0 if count % 2 == 0 else sorted[middle]
	return {"samples": count, "mean": total / count, "median": median, "p95": sorted[ceili(0.95 * count) - 1]}


static func _coast_fraction(map: MapData, area: Rect2, hex_size: float) -> Vector2:
	var counts := Vector2.ZERO
	for y in range(2, 17):
		for x in range(2, 31):
			var point := area.position + area.size * Vector2(float(x) / 32.0, float(y) / 18.0)
			var cube := HexUtils.world_to_wrapped_cube(point, hex_size, map.width, map.height)
			if cube.x == 2147483647:
				continue
			var offset := HexUtils.cube_to_offset(cube.x, cube.y)
			var index := offset.y * map.width + offset.x
			if map.explored_arr[index] != 0:
				if map.is_water_arr[index] == 0:
					counts.x += 1.0
				else:
					counts.y += 1.0
	return counts / 435.0


static func _position_camera(camera: MapCamera, point: Vector2) -> void:
	camera.position = point
	camera._clamp_position()
	camera.force_update_scroll()
	camera._emit_view_changed_if_needed()


static func record_coast(game: PlayerGame, map: MapData, output: String) -> bool:
	var renderer := game._renderer
	var water := renderer._water_quad
	var land := renderer._world_quad
	var camera := game._camera
	var window := game.get_tree().root
	if renderer._mobile_quality_tier_define != "MOBILE_QUALITY_LOW" or game.visual_quality != 0 \
			or water == null or land == null or water.mesh == null or land.mesh == null \
			or water.get_viewport() != window or land.get_viewport() != window:
		return false
	var layer := water.visibility_layer
	if layer == 0:
		return false
	var hex_size: float = renderer.hex_size
	camera.restore_view_state(camera.position, 1.75)
	var view: Rect2 = camera.current_world_view_rect()
	# Freeze the route selected in the November 2026 device run, before its first measured step.
	var left := Vector2(1059.36376953125, 924.0)
	var right := left + Vector2(320, 0)
	var fractions: Array[Vector2] = []
	for t: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var center := left.lerp(right, t)
		var share := _coast_fraction(map, Rect2(center - view.size / 2.0, view.size), hex_size)
		if minf(share.x, share.y) < 0.15:
			push_error("The fixed coast route no longer shows both explored land and water.")
			return false
		fractions.append(share)
	var base_day := game._world_clock.day_index()
	if base_day != 3 or not is_equal_approx(camera.zoom.x, 1.75):
		return false
	var base_zoom: float = camera.zoom.x
	var base_window := window.size
	for arm in range(4):
		var omit := arm % 2 == 1
		water.visibility_layer = 0 if omit else layer
		_position_camera(camera, left)
		for _frame in range(WARMUP_FRAMES):
			await RenderingServer.frame_post_draw
		var intervals: Array[float] = []
		var draws: Array[int] = []
		var centers := PackedVector2Array()
		var valid := true
		var start := Time.get_unix_time_from_system()
		var previous := Time.get_ticks_usec()
		for frame in range(SAMPLE_FRAMES):
			var wanted := left.lerp(right, float(frame + 1) / SAMPLE_FRAMES)
			_position_camera(camera, wanted)
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			intervals.append(float(now - previous) / 1000.0)
			previous = now
			centers.append(camera.get_screen_center_position())
			valid = valid and centers[-1].is_equal_approx(wanted) and camera.zoom.x == base_zoom \
				and window.size == base_window and game._world_clock.day_index() == base_day \
				and water.visibility_layer == (0 if omit else layer) and water.is_visible_in_tree()
			draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		var end := Time.get_unix_time_from_system()
		var image := window.get_texture().get_image()
		if image == null:
			return false
		var screenshot := output.path_join("coast-%d.png" % arm)
		var screenshot_ok := image.save_png(screenshot) == OK
		var points: Array = []
		for center in centers:
			points.append([center.x, center.y])
		var coverage: Array = []
		for share in fractions:
			coverage.append([share.x, share.y])
		var report := {
			"ok": valid and screenshot_ok and image.get_width() > 0 and image.get_height() > 0 and draws.min() > 0,
			"protocol": "coast-pan-v1", "platform": OS.get_name(), "model": OS.get_model_name(),
			"build": "debug" if OS.is_debug_build() else "release",
			"screen_px": [window.size.x, window.size.y], "godot": Engine.get_version_info().string,
			"scene": "explored-coast", "arm": arm, "day": base_day, "omitted_layer": "water" if omit else "",
			"scale_percent": 100, "process_id": OS.get_process_id(), "start_unix_s": start, "end_unix_s": end,
			"frame_interval_ms": _summary(intervals), "raw_frame_interval_ms": intervals,
			"draw_calls": _summary(draws), "camera_zoom": base_zoom, "camera_centers": points,
			"explored_land_water_fractions": coverage, "window_px": [image.get_width(), image.get_height()],
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"adapter": RenderingServer.get_video_adapter_name(),
			"refresh_hz": DisplayServer.screen_get_refresh_rate(),
			"vsync": DisplayServer.window_get_vsync_mode(),
			"engine_max_fps": Engine.max_fps,
		}
		var data := FileAccess.open(output.path_join("coast-%d.json" % arm), FileAccess.WRITE)
		if data == null:
			return false
		data.store_string(JSON.stringify(report))
		data.close()
		print("[mobile-coast-draw] ", JSON.stringify({"arm":arm,"ok":report.ok,
			"start_unix_s":start,"end_unix_s":end,"frame_interval_ms":report.frame_interval_ms,
			"window_px":report.window_px,"day":report.day,"adapter":report.adapter,"driver":report.driver}))
		if not report.ok:
			return false
	return true
