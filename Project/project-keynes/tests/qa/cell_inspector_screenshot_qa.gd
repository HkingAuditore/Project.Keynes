extends SceneTree

## Tile inspector screenshot QA: start a real game, run a few days, then select the player start cell,
## a neighbouring wild cell and a water cell, and capture every tab at 1280x720 / 1366x768 / 1920x1080.
## Must run with rendering (without --headless).

const OUTPUT_DIR := "res://tmp/cell_inspector_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080)]
const WARMUP_DAYS := 10

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	root.size = SIZES[0]
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	await process_frame
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	var controller = ui.get("_player_controller")
	var start_day := clock.day_index()
	clock.pause(false)
	clock.set_speed(50.0)
	var deadline := Time.get_ticks_msec() + 60000
	while clock.day_index() < start_day + WARMUP_DAYS and Time.get_ticks_msec() < deadline:
		await process_frame
	clock.pause(true)
	var map: MapData = runtime.get("_current_map")
	var start := int(runtime.call("_resolve_player_start_cell"))
	var targets := {"home": start}
	var start_cell := map.cell_at(start)
	for neighbor in map.get_neighbors(start_cell):
		var cell := neighbor as HexCell
		if cell == null:
			continue
		if not targets.has("wild") and TerrainType.is_passable_land(cell.terrain) \
				and int(map.country_slot_arr[cell.index]) != int(map.country_slot_arr[start]):
			targets["wild"] = cell.index
		if not targets.has("water") and TerrainType.is_passable_sea(cell.terrain):
			targets["water"] = cell.index
	if not targets.has("wild"):
		for neighbor in map.get_neighbors(start_cell):
			var cell := neighbor as HexCell
			if cell != null and TerrainType.is_passable_land(cell.terrain):
				targets["wild"] = cell.index
				break
	var panel := ui.get("_right_panel") as InspectorPanel
	for viewport_size in SIZES:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(viewport_size)
		root.size = viewport_size
		for label in targets:
			controller.select_cell(map.cell_at(int(targets[label])))
			await process_frame
			await process_frame
			var tabs: Array = (panel.get("_model") as Dictionary).get("tabs", [])
			if tabs.is_empty():
				await _capture("%s_none" % label, viewport_size)
			for tab in tabs:
				panel.select_tab(String((tab as Dictionary).get("id", "")))
				await _capture("%s_%s" % [label, String((tab as Dictionary).get("id", ""))],
					viewport_size)
			panel.select_tab("geography")
	_finish()


func _capture(label: String, viewport_size: Vector2i) -> void:
	await create_timer(UITokens.ANIM_MED + 0.2).timeout
	var path := "%s/%s_%dx%d.png" % [OUTPUT_DIR, label, viewport_size.x, viewport_size.y]
	for attempt in 4:
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image != null and not image.is_empty() and image.save_png(path) == OK:
			print("[cell-inspector-screenshot] %s" % ProjectSettings.globalize_path(path))
			return
		await process_frame
	_failures.append("failed to capture %s" % path)


func _finish() -> void:
	for failure in _failures:
		push_error(failure)
	print("=== cell inspector screenshot QA: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)

