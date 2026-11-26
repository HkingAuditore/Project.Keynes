extends "res://tests/game/player_scene_handoff_probe.gd"

## Pixel readback is intentional here. The performance runs use the unmodified
## player handoff probe and never read back the offscreen texture.
const TEST_FPS := 60
var failures: Array[String] = []
var ui_days: Array[int] = []


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("independent presentation requires a drawable window")
		quit(1)
		return
	root.always_on_top = true
	root.grab_focus()
	var settings := root.get_node("GameSettings")
	var window_settings := {"window_mode": "windowed", "resolution_width": 1600,
		"resolution_height": 960, "vsync": true, "render_quality": "high",
		"autosave_enabled": false, "ai_narrative_enabled": false}
	window_settings.merge(GraphicsSettings.resolve(window_settings, OS.has_feature("mobile")), true)
	window_settings.graphics_custom = true
	window_settings.frame_rate_limit = TEST_FPS
	settings.update(window_settings, false)
	var config := NewGameConfig.new()
	config.apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.country.foreign_count = 3
	var start := await _start_player_scene(root.get_node("GameFlow"), config)
	if not start.get("ok", false):
		printerr(start)
		quit(1)
		return
	var scene := current_scene as PlayerGame
	_host = scene.get_node("RuntimeHost")
	_clock = scene.get_node("WorldClock")
	_clock.pause(true)
	_camera = scene.get_node("MapCamera")
	var target = scene.get_node("MapViewport")
	var ui: GameUIManager = scene.get_node("UI")
	var top = ui.get_node("UIRoot/HUDLayer/PlayerTopBar")
	var image := scene.get_node("MapOutput/MapImage") as TextureRect
	var loading := ui.get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as Control
	while loading.visible or not image.visible or _camera.drawn_frame == null or not _camera.drawn_frame.valid:
		await RenderingServer.frame_post_draw
	check(target.find_world_2d() != root.find_world_2d(), "world draws only in the map viewport")
	check(target.size == Vector2i(1600, 960), "map uses the full configured drawing size")
	check(Engine.max_fps == TEST_FPS, "the window uses the 60 fps map budget")
	_host.publication_reader.interval_usec = 100000
	_host.execute_gm_command("time.speed", {"value": 5})
	if not await wait_for_received_day(1, func(): return _camera.drawn_frame.day >= 1):
		finish()
		return
	_clock.pause(true)
	_host.simulation_ui_updated.connect(func(_from, day, _generation): ui_days.append(day))
	_host.simulation_day_records.connect(_record_days)
	_timings.attach(_host)
	var start_day := _host.received_worker_day()
	var command: Dictionary = COMMAND_LOG[0].duplicate()
	command.requested_day = maxi(0, start_day) + 2
	var receipt: Dictionary = _host.generator().get_data_core_world_ext().submit_runtime_command(command)
	check(receipt.get("admitted", receipt.get("ok", false)), "production command admitted")
	var frozen_day: int = _camera.drawn_frame.day
	var frozen_transform := _camera.drawn_frame.transform
	var sample := ui.map_safe_area().get_center()
	var frozen_world := _camera.safe_screen_to_world(sample)
	var count: int = target.draw_count
	var texture_before: Image = target.get_texture().get_image()
	check(has_map_pixels(texture_before), "held image contains the playable map")
	var window_before := root.get_texture().get_image()
	# Sample the map's open play area in the composited window as well as its own texture.
	var region := Rect2i(Vector2i(ui.map_safe_area().get_center()) - Vector2i(72, 56), Vector2i(144, 112))
	check(has_map_pixels(window_before.get_region(region)), "terrain is visible behind the HUD before holding")
	save_image("01-map", texture_before)
	save_image("01-window", window_before)
	target.draw_enabled = false
	var date_before: String = top._date_label.text
	var receipt_seen := false
	# The host has already marked the start of each frame when this runs.
	var occupy_frame := func(): OS.delay_usec(roundi(1_000_000.0 / TEST_FPS))
	process_frame.connect(occupy_frame)
	_clock.pause(false)
	var arrived := await wait_for_received_day(int(receipt.effective_day) + 1)
	process_frame.disconnect(occupy_frame)
	_clock.pause(true)
	if not arrived:
		finish()
		return
	for row in _day_rows:
		for result in row.receipts:
			if int(result.request_id) == int(command.request_id):
				receipt_seen = true
				check(int(row.day) == int(receipt.effective_day), "receipt arrived on its sealed day")
	check(receipt_seen, "command receipt arrives while map is held")
	check(not ui_days.is_empty() and date_before != top._date_label.text, "date updates on the held map")
	var busy := _timings.take()
	check(busy.received_batches > 0 and busy.map_copies.is_empty() and target.draw_count == count,
		"busy window frames receive results without reading the map")
	var held_day := _host.received_worker_day()
	if not await wait_for_received_day(held_day, func(): return target._frame.staged_day >= held_day):
		finish()
		return
	check(not _timings.take().map_copies.is_empty() and target.draw_count == count,
		"the map stages its latest textures when the budget allows while drawing stays held")
	var old_camera_pos := _camera.position
	var old_zoom := _camera.zoom
	push_button(MOUSE_BUTTON_RIGHT, sample, true)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(80, 0)
	drag.position = sample + drag.relative
	drag.button_mask = MOUSE_BUTTON_MASK_RIGHT
	root.push_input(drag, true)
	push_button(MOUSE_BUTTON_RIGHT, drag.position, false)
	push_button(MOUSE_BUTTON_WHEEL_UP, sample, true)
	check(_camera.position != old_camera_pos and _camera._target_zoom != old_zoom,
		"the player can drag and zoom while map drawing is held")
	await RenderingServer.frame_post_draw
	check(frozen_world.is_equal_approx(_camera.safe_screen_to_world(sample)), "hit uses the drawn transform")
	check(_camera.drawn_frame.transform == frozen_transform and _camera.drawn_frame.day == frozen_day,
		"pending camera and data do not replace the drawn map")
	var tapped: Array[Vector2] = []
	_camera.tile_tapped.connect(func(point): tapped.append(point), CONNECT_ONE_SHOT)
	for pressed in [true, false]:
		push_button(MOUSE_BUTTON_LEFT, sample, pressed)
	check(tapped.size() == 1 and tapped[0].is_equal_approx(frozen_world), "tap dispatch matches the visible cell")
	var clicked_cell: HexCell = HexUtils.world_to_wrapped_cell(_host.current_map(), frozen_world, _host.hex_size)
	check(clicked_cell != null and ui._right_panel.visible and ui._right_panel._cell_index == clicked_cell.index,
		"frozen map click opens the matching cell inspector")
	check(ui._right_panel._model.get("tabs", []).is_empty(), "frozen cell summary excludes unpublished details")
	if clicked_cell != null:
		var unexplored: bool = _camera.drawn_frame.explored[clicked_cell.index] == 0
		check((ui._right_panel._model.header.title == "未探索区域") == unexplored,
			"frozen inspector uses the exploration knowledge in the drawn picture")
	ui.toggle_pause_menu()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(ui._pause_menu.visible, "pause menu can open on a held map")
	check(window_before.get_data() != root.get_texture().get_image().get_data(), "window independently redrew UI")
	check(target.draw_count == count and texture_before.get_data() == target.get_texture().get_image().get_data(),
		"map pixels and draw count are frozen")
	save_image("02-held-window", root.get_texture().get_image())
	ui.toggle_pause_menu()
	var notifications := ui_days.size()
	var held_ui_date: String = top._date_label.text
	_host._presentation.ui_refresh_enabled = false
	target.draw_enabled = true
	_clock.pause(false)
	var resume_day := _host.received_worker_day() + 2
	if not await wait_for_received_day(resume_day, func(): return _camera.drawn_frame.day >= resume_day):
		finish()
		return
	check(target.draw_count > count and ui_days.size() == notifications, "map draws while ordinary UI is held")
	check(top._date_label.text == held_ui_date, "ordinary date stays held")
	check(texture_before.get_data() != target.get_texture().get_image().get_data(), "next map contains new pixels")
	check(not frozen_world.is_equal_approx(_camera.safe_screen_to_world(sample)), "hit follows the newly drawn camera")
	check(not ui._cell_panel._waiting_for_drawn_cell, "new map draw releases the inspector's detail query")
	_host._presentation.ui_refresh_enabled = true
	await RenderingServer.frame_post_draw
	check(ui_days.back() == _host.received_worker_day(), "UI catches up to the latest received batch")
	_clock.pause(true)
	root.size = Vector2i(1280, 720)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(target.size == Vector2i(1280, 720), "resize propagates to the map")
	save_image("03-resized-window", root.get_texture().get_image())
	_host.set_map_overlay({"mode": OverlayMode.MODE.ELEVATION})
	await RenderingServer.frame_post_draw
	check(_host.map_overlay_diagnostics().active and scene.get_node("%WorldRoot/DataOverlayLayer").visible,
		"thematic map draws in the independent viewport")
	var saved: Dictionary = await root.get_node("GameSave").request_manual_save("manual_1")
	check(saved.get("ok", false), "current playable world saved")
	if saved.get("ok", false):
		await check_reloaded_world(scene)
	var old_map := _host.current_map()
	image = current_scene.get_node("MapOutput/MapImage")
	var closed: Dictionary = await _host.close_world()
	check(closed.get("ok", false) and MapDrawnFrame.for_map(old_map) == null and not image.visible,
		"closing the world detaches the cached picture")
	finish()


func finish() -> void:
	for item in failures:
		printerr(item)
	print("INDEPENDENT_WINDOW=", JSON.stringify({"failures": failures, "ui_days": ui_days,
		"days": _day_rows.size(), "driver": RenderingServer.get_current_rendering_driver_name()}))
	quit(0 if failures.is_empty() else 1)


func wait_for_received_day(day: int, map_ready: Callable = Callable()) -> bool:
	var generator := _host.generator()
	var started := Time.get_ticks_usec()
	while true:
		var committed := int(generator.get_runtime_control_state().get("simulation_committed_day", -1))
		var received := _host.received_worker_day()
		if _host.is_runtime_fault_paused():
			check(false, "runtime fault waiting for day %d" % day)
			return false
		if committed >= day and received >= day and (not map_ready.is_valid() or map_ready.call()):
			return true
		if Time.get_ticks_usec() - started >= WATCHDOG_USEC:
			check(false, "window wait for day %d timed out: committed=%d received=%d" % [day, committed, received])
			return false
		await process_frame
	return false


func check_reloaded_world(previous: PlayerGame) -> void:
	var previous_id := previous.get_instance_id()
	var old_map := _host.current_map()
	var old_frame = MapDrawnFrame.for_map(old_map)
	var saved_day := _host.received_worker_day()
	var first_draw: Array[int] = []
	var on_node := func(node: Node):
		if node.name == &"MapViewport" and node.get_parent() is PlayerGame:
			check(not node.get_parent().get_node("MapOutput/MapImage").is_visible_in_tree(),
				"new scene starts with no displayed map")
			node.map_view_drawn.connect(func(day: int):
				first_draw.append(day)
				check(MapDrawnFrame.for_map(old_map) == null and node._frame != old_frame,
					"first load draw belongs exclusively to the restored world")
				check(has_map_pixels(node.get_texture().get_image()), "first restored map contains terrain")
				check(node.get_parent().get_node("RuntimeHost").ui_worker_day() == saved_day,
					"the first restored UI date matches the save")
			, CONNECT_ONE_SHOT)
	node_added.connect(on_node)
	var flow := root.get_node("GameFlow")
	var started: Dictionary = flow.begin_load_game("manual_1")
	var failures_loading: Array[Dictionary] = []
	var failed := func(info: Dictionary): failures_loading.append(info)
	flow.player_start_failed.connect(failed)
	if started.get("ok", false):
		started = await _wait_for_player_scene(flow, previous_id, failures_loading)
	if flow.player_start_failed.is_connected(failed):
		flow.player_start_failed.disconnect(failed)
	node_added.disconnect(on_node)
	check(started.get("ok", false), "saved world reopened through GameFlow")
	if not started.get("ok", false):
		return
	_host = _player_host()
	var surface := current_scene.get_node("MapOutput/MapImage") as TextureRect
	while first_draw.is_empty() or not surface.visible:
		await RenderingServer.frame_post_draw
	check(first_draw.front() == saved_day and not _host.map_overlay_diagnostics().active,
		"first restored map uses the saved date and starts with overlays closed")
	save_image("04-restored-map", surface.texture.get_image())


func has_map_pixels(img: Image) -> bool:
	var thumbnail := img.duplicate() as Image
	thumbnail.resize(48, 32, Image.INTERPOLATE_NEAREST)
	var colors := {}
	for y in thumbnail.get_height():
		for x in thumbnail.get_width():
			colors[thumbnail.get_pixel(x, y)] = true
	return colors.size() > 1


func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)


func push_button(button: MouseButton, point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.pressed = pressed
	root.push_input(event, true)


func save_image(label: String, img: Image) -> void:
	var directory := OS.get_environment("PK_PRESENTATION_CAPTURE_DIR")
	if not directory.is_empty():
		img.save_png(directory.path_join(label + ".png"))
