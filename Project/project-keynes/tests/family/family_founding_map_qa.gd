extends SceneTree

## Rendered production-map QA; candidates are presentation fixtures, never submitted.
const OUTPUT := "res://tmp/family_founding_map_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768),
	Vector2i(1920, 1080), Vector2i(2560, 1440)]
var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_factor = 1.0
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	root.size = SIZES[0]
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		flow = load("res://scripts/game/game_flow_service.gd").new()
		flow.name = "GameFlow"
		root.add_child(flow)
	var config := NewGameConfig.create_default()
	config.base["map_width"] = 40
	config.base["map_height"] = 28
	config.country["foreign_count"] = 0
	flow.set("_pending_request", {"kind": "new_game", "config": config.to_dictionary()})
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	game.visual_quality = 0
	root.add_child(game)
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	await runtime.world_ready
	var clock: WorldClock = game.get_node("WorldClock")
	clock.pause(true)
	var ui := game.get_node("UI") as GameUIManager
	var controller = ui.get("_player_controller")
	var map: MapData = runtime.get("_current_map")
	var home := map.cell_at(int(runtime.call("_resolve_player_start_cell")))
	controller.select_cell(home)
	var offer := {"offer_id": 90001, "generation": 1, "cell": home.index,
		"settlement_name": "本城", "milestone_population": 200,
		"cell_population": 216, "queue_remaining": 2, "candidates": [
			_candidate("张", "采集营地", "采集者"), _candidate("李", "伐木场", "伐木工"),
			_candidate("王", "狩猎营地", "猎人")]}
	var dialog := ui.get("_family_founding_dialog") as FamilyFoundingDialog
	var inspector := ui.get("_right_panel") as InspectorPanel
	for viewport_size in SIZES:
		DisplayServer.window_set_size(viewport_size)
		root.size = viewport_size
		ui.show_family_founding_offer(offer)
		ui.call("_layout_family_founding_dialog")
		controller.ensure_selected_visible()
		await create_timer(0.35).timeout
		var surface := dialog.get_node("ArchiveSurface") as Control
		_expect(not surface.get_global_rect().intersects(inspector.get_global_rect()),
			"ordinary inspector stays clear at %s" % viewport_size)
		_expect(ui.map_safe_area().position.x >= surface.get_global_rect().end.x,
			"camera bounds exclude founding dossier at %s" % viewport_size)
		await _capture("summary_%dx%d" % [viewport_size.x, viewport_size.y])
		var first := dialog.get_node("%CardGrid").get_child(0) as FamilyFoundingCard
		first.details_button().pressed.emit()
		await create_timer(0.3).timeout
		_expect(first.is_details_expanded(), "details open at %s" % viewport_size)
		_expect(absf((first.get_node("%DetailsContent") as Control).size.x
			- (first.get_node("%DetailsClip") as Control).size.x) <= 1.0,
			"detail copy fits card width at %s" % viewport_size)
		await _capture("detail_%dx%d" % [viewport_size.x, viewport_size.y])
		first.details_button().pressed.emit()
		await create_timer(0.2).timeout
	await _check_map_input(ui, game.get_node("MapCamera") as MapCamera)
	var card := dialog.get_node("%CardGrid").get_child(1) as FamilyFoundingCard
	card.details_button().pressed.emit()
	await create_timer(0.3).timeout
	var scroll := dialog.get_node("%CardsScroll") as ScrollContainer
	scroll.scroll_vertical = 60
	var saved_scroll := scroll.scroll_vertical
	inspector.show_object_detail({"title": "采集营地", "subtitle": "本地产业",
		"tabs": [{"id": "overview", "label": "概况"}], "categories": {"overview": {}}})
	await create_timer(0.2).timeout
	_expect(dialog.is_collapsed(), "formal inspector signal automatically collapses founding panel")
	await _capture("inspector_avoidance")
	(dialog.get_node("%CollapsedEntry") as Button).pressed.emit()
	await create_timer(0.25).timeout
	_expect(not inspector.detail_open() and not dialog.is_collapsed(),
		"pending entry closes large inspector and restores founding panel")
	_expect(card.is_details_expanded() and scroll.scroll_vertical == saved_scroll,
		"inspector avoidance preserves expanded house and scroll")
	dialog.set_collapsed(true, false)
	inspector.show_object_detail({"title": "采集营地"})
	await process_frame
	inspector.close_detail()
	await process_frame
	_expect(dialog.is_collapsed(), "formal inspector signals preserve manual collapse")
	await _capture("collapsed")
	ui.close_family_founding_offer()
	await create_timer(0.2).timeout
	game.queue_free()
	await process_frame
	print("family founding map QA: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _candidate(surname: String, building: String, profession: String) -> Dictionary:
	return {"family_name": "长安%s氏" % surname, "building_display_name": building,
		"owner_profession_display_name": profession, "founders": 42,
		"trait_display_names": PackedStringArray(["节俭", "产业专精", "开拓门风", "勤勉"]),
		"trait_descriptions": PackedStringArray(["日常消费减少 10%。", "投资相关产业的可能性增加 50%。",
			"更倾向参与开拓，并在合法的职业与产业范围内寻找新的发展机会。", "从业偏好增加 20%。"]),
		"effect_display_name": "专精产业", "effect_prestige_descriptions": PackedStringArray([
			"威望Ⅰ：本地块产出提高 2%。", "威望Ⅱ：本地块产出提高 4%。",
			"威望Ⅲ：本地块产出提高 6%。", "威望Ⅳ：本地块产出提高 8%。",
			"威望Ⅴ：本地块产出提高 10%。"])}


func _check_map_input(ui: GameUIManager, camera: MapCamera) -> void:
	var area := ui.map_safe_area()
	var point := area.get_center()
	var previous_zoom: Vector2 = camera.get("_target_zoom")
	var wheel := InputEventMouseButton.new()
	wheel.position = point
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await process_frame
	_expect((camera.get("_target_zoom") as Vector2) != previous_zoom,
		"map wheel zoom passes through outside founding panel")
	var previous_position := camera.position
	var press := InputEventMouseButton.new()
	press.position = point
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(30.0, 20.0)
	motion.relative = Vector2(30.0, 20.0)
	motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	Input.parse_input_event(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = motion.position
	release.button_index = MOUSE_BUTTON_MIDDLE
	Input.parse_input_event(release)
	await process_frame
	_expect(camera.position != previous_position, "map drag passes through outside founding panel")


func _capture(label: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_expect(image != null and image.save_png("%s/%s.png" % [OUTPUT, label]) == OK,
		"capture %s" % label)


func _expect(condition: bool, message: String) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)
