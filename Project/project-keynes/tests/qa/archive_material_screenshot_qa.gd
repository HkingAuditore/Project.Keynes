extends SceneTree

## Run with rendering. Captures the formal game and verifies that material
## projection leaves layout/input bounds intact at all supported desktop sizes.
const OUTPUT := "res://tmp/archive_material_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768),
	Vector2i(1920, 1080), Vector2i(2560, 1080)]
var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	root.size = SIZES[0]
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	root.add_child(game)
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	await runtime.world_ready
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	clock.pause(true)
	var map: MapData = runtime.get("_current_map")
	var home := map.cell_at(int(runtime.call("_resolve_player_start_cell")))
	var controller = ui.get("_player_controller")
	controller.select_cell(home)
	await create_timer(0.4).timeout
	var panel := ui.get("_right_panel") as InspectorPanel
	panel.select_tab("geography")
	await process_frame
	var panel_id := panel.get_instance_id()
	var nav_id := (panel.get("_chapter_nav") as Control).get_instance_id()
	var scroll := panel.get("_scroll") as ScrollContainer
	var scroll_id := scroll.get_instance_id()
	var initial_day := clock.day_index()
	clock.set_speed(50.0)
	clock.pause(false)
	var deadline := Time.get_ticks_msec() + 90000
	while clock.day_index() < initial_day + 10 and Time.get_ticks_msec() < deadline:
		await process_frame
	clock.pause(true)
	_expect(clock.day_index() >= initial_day + 10, "50x simulation advanced ten days")
	_expect(panel.get_instance_id() == panel_id
		and (panel.get("_chapter_nav") as Control).get_instance_id() == nav_id
		and (panel.get("_scroll") as Control).get_instance_id() == scroll_id,
		"50x preserved panel, chapter navigation and scroll instances")
	for attempt in range(6):
		ui.hide_cell_panel()
		ui.show_cell_panel(home)
		await process_frame
	await create_timer(0.3).timeout
	_expect(panel.visible and is_equal_approx(panel.modulate.a, 1.0),
		"rapid reopen cancels the pending close transition")
	for viewport in SIZES:
		DisplayServer.window_set_size(viewport)
		root.size = viewport
		await create_timer(0.4).timeout
		ui.call("_layout_right_panel")
		await process_frame
		var camera := game.get_node("MapCamera") as MapCamera
		camera.zoom *= 1.5
		camera.set("_target_zoom", camera.zoom)
		controller.ensure_selected_visible()
		await create_timer(0.25).timeout
		var rect := panel.get_global_rect()
		var logical_width := ui.get_viewport().get_visible_rect().size.x
		_expect(absf(rect.end.x - (logical_width - UITokens.ARCHIVE_EDGE_INSET)) < 1.0,
			"inspector has a 16px right inset at %s" % viewport)
		_expect(absf(rect.size.x - GameUIManager.RIGHT_PANEL_WIDTH) < 1.0,
			"inspector keeps its 460px layout width at %s" % viewport)
		await _capture("map_%dx%d" % [viewport.x, viewport.y])
	DisplayServer.window_set_size(SIZES[1])
	root.size = SIZES[1]
	await create_timer(0.3).timeout
	await _capture_fog_states(ui, map, home)
	controller.select_cell(home)
	await create_timer(0.3).timeout
	await _capture_button_states(game)
	ui.open_country_section("economy")
	await create_timer(0.6).timeout
	for attempt in range(3):
		ui.close_country_panel()
		ui.open_country_section("economy")
		await process_frame
	await create_timer(0.3).timeout
	var country := ui.get("_country_panel") as CountryPanel
	_expect(country.is_panel_open() and is_equal_approx(country.modulate.a, 1.0),
		"rapid country reopen cancels the pending close transition")
	var compact_close := country.get_node("%CompactClose") as Button
	_expect(not bool(country.get("_compact")) or compact_close.is_visible_in_tree(),
		"compact country keeps a visible close action")
	await _capture("country_economy")
	ui.close_country_panel()
	await create_timer(0.3).timeout
	for failure in _failures:
		push_error(failure)
	print("[archive-material-qa] %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _capture_fog_states(ui: GameUIManager, map: MapData, home: HexCell) -> void:
	var targets := {}
	for cell in map.iter_cells():
		var fog := VisionSolver.fog_state(map, cell.index)
		if not targets.has(fog):
			targets[fog] = cell
		if targets.size() == 3:
			break
	# The opening game may have no remembered-only cells. A UI-only model fixture
	# exercises that presentation without changing any world visibility state.
	var panel := ui.get("_right_panel") as InspectorPanel
	for fog in [VisionSolver.FOG_UNEXPLORED, VisionSolver.FOG_EXPLORED, VisionSolver.FOG_VISIBLE]:
		var model: Dictionary
		if targets.has(fog):
			ui.show_cell_panel(targets[fog])
			model = panel.get("_model")
		elif fog == VisionSolver.FOG_EXPLORED:
			var fixture_map := MapData.new(1, 1)
			fixture_map.visible_arr = PackedByteArray([0])
			fixture_map.explored_arr = PackedByteArray([1])
			var fixture_cell := HexCell.new()
			fixture_cell.index = 0
			fixture_cell.terrain = home.terrain
			fixture_cell.elevation = home.elevation
			var fixture_vm := CellInspectorViewModel.new()
			fixture_vm.set_context(fixture_map, null, null, null, 0.42, 22.0)
			model = fixture_vm.build(fixture_cell)
			panel.set_model_for_selection(model)
			panel.visible = true
		else:
			_failures.append("missing fog target %d" % fog)
			continue
		var tabs: Array = model.get("tabs", [])
		_expect(fog != VisionSolver.FOG_UNEXPLORED or tabs.is_empty(),
			"unexplored presentation has no tabs")
		_expect(fog != VisionSolver.FOG_EXPLORED or tabs.size() == 1,
			"remembered presentation has geography only")
		await create_timer(0.3).timeout
		await _capture("fog_%d" % fog)


func _capture_button_states(_game: Node) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 360)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.10, 0.13, 0.17)
	backdrop.size = Vector2(viewport.size)
	viewport.add_child(backdrop)
	var sheet := PanelContainer.new()
	sheet.theme = load("res://assets/themes/player_session_theme.tres")
	sheet.theme_type_variation = &"PKArchivePanel"
	sheet.position = Vector2(32.0, 32.0)
	sheet.size = Vector2(736.0, 284.0)
	viewport.add_child(sheet)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	sheet.add_child(body)
	var title := Label.new()
	title.text = "材质状态 · 羊皮纸与珐琅"
	title.theme_type_variation = &"PKTitle"
	body.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(row)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var button := Button.new()
		button.text = {"normal": "普通", "hover": "悬停", "pressed": "选中", "disabled": "禁用"}[state]
		button.theme_type_variation = &"PKHUDButton"
		button.custom_minimum_size = Vector2(142, 60)
		row.add_child(button)
		if state == "hover":
			button.add_theme_stylebox_override("normal", sheet.theme.get_stylebox("hover", "PKHUDButton"))
		if state == "pressed":
			button.toggle_mode = true
			button.button_pressed = true
		if state == "disabled":
			button.disabled = true
	await process_frame
	await RenderingServer.frame_post_draw
	var closeup := viewport.get_texture().get_image()
	_expect(closeup != null and closeup.save_png(OUTPUT + "/material_closeup.png") == OK,
		"material closeup")
	viewport.queue_free()
	await process_frame


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT, label]
	_expect(shot != null and shot.save_png(path) == OK, "capture %s" % label)
	print("[archive-material-qa] %s" % ProjectSettings.globalize_path(path))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
