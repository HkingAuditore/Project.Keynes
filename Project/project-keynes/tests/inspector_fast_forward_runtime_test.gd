extends SceneTree

## 正式 worker 对局中首次打开各页，并在 50x 下跨帧点击详情。
var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var config := NewGameConfig.create_default()
	config.base.initial_seed = 123456
	config.base.map_width = 40
	config.base.map_height = 28
	config.country.foreign_count = 0
	root.get_node("GameFlow").set("_pending_request", {
		"kind": "new_game", "config": config.to_dictionary()})
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime := game.get_node("RuntimeHost") as WorldRuntimeHost
	root.add_child(game)
	await runtime.world_ready
	var ui := game.get_node("UI") as GameUIManager
	# world_ready 先于加载幕的退场动画；真实玩家要等遮罩退出后才能点击。
	while ui._loading_overlay.visible:
		await process_frame
	var clock := game.get_node("WorldClock") as WorldClock
	var panel := ui._right_panel
	var map: MapData = runtime.get("_current_map")
	var start := int(runtime.call("_resolve_player_start_cell"))
	ui._player_controller.select_cell(map.cell_at(start))
	clock.set_speed(50.0)
	clock.pause(false)
	var first_day := clock.day_index()
	for tab in ["population", "market", "buildings", "families", "geography"]:
		panel.select_tab(tab)
		var deadline := Time.get_ticks_msec() + 5000
		while not ui._pending_inspector_tab.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
		await create_timer(0.2).timeout
		if not ui._pending_inspector_tab.is_empty():
			_failures.append("%s did not resolve its first snapshot" % tab)
			continue
		var list: Control = {"population": panel._cohort_list, "market": panel._market_list,
			"buildings": panel._building_list, "families": panel._family_list,
			"geography": panel._resource_list}.get(tab)
		if list == null:
			if tab != "families":
				_failures.append("%s has no list after its first snapshot" % tab)
			continue
		var button: Button
		for refs in list.get("_row_refs").values():
			var candidate := (refs as Dictionary).get("button") as Button
			if candidate.is_visible_in_tree():
				button = candidate
				break
		if button == null:
			continue
		panel._scroll.ensure_control_visible(button)
		await process_frame
		await process_frame
		var point := button.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = point
		root.push_input(motion, true)
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.position = point
		down.pressed = true
		root.push_input(down, true)
		await create_timer(0.12).timeout
		var up := down.duplicate() as InputEventMouseButton
		up.pressed = false
		root.push_input(up, true)
		deadline = Time.get_ticks_msec() + 5000
		while not panel.detail_open() and Time.get_ticks_msec() < deadline:
			await process_frame
		if not panel.detail_open():
			_failures.append("%s click did not open details at 50x" % tab)
		else:
			print("[inspector-fast-forward] opened %s at day %d" % [tab, clock.day_index()])
		panel.close_detail(false)
		await process_frame
	clock.pause(true)
	if clock.day_index() <= first_day:
		_failures.append("simulation did not advance during the UI checks")
	for failure in _failures:
		push_error("[inspector-fast-forward] FAIL: %s" % failure)
	print("[inspector-fast-forward] %s days=%d" % [
		"PASS" if _failures.is_empty() else "FAIL", clock.day_index() - first_day])
	game.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)
