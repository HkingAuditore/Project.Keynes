extends SceneTree

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _check_main_menu()
	await _check_world_setup()
	await _check_player_game()
	print("ui scene structure: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _check_main_menu() -> void:
	var packed := load("res://scenes/main_menu.tscn") as PackedScene
	var scene := packed.instantiate()
	_expect("main menu has static page stack", scene.has_node("PageMargin/PageStack"))
	for page_name in ["HomePage", "NewGamePage", "LoadGamePage", "SettingsPage"]:
		_expect("main menu has %s" % page_name,
			scene.has_node("PageMargin/PageStack/%s" % page_name))
	root.add_child(scene)
	await process_frame
	_expect("main menu keeps four static pages",
		scene.get_tree().get_nodes_in_group("main_menu_pages").size() == 4)
	scene.queue_free()
	await process_frame


func _check_world_setup() -> void:
	var packed := load("res://scenes/world_setup.tscn") as PackedScene
	var scene := packed.instantiate()
	_expect("world setup has static header", scene.has_node("Margin/Root/Header"))
	_expect("world setup has static responsive body",
		scene.has_node("Margin/Root/ResponsiveBody"))
	root.add_child(scene)
	await process_frame
	_expect("world setup creates reusable field rows",
		scene.get_tree().get_nodes_in_group("world_setup_field_rows").size() > 10)
	scene.queue_free()
	await process_frame


func _check_player_game() -> void:
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var scene := packed.instantiate()
	var ui := scene.get_node("UI")
	var fixed_names := ["PlayerTopBar", "RightPanel", "DemandDetailDialog",
		"ObjectDetailDialog", "PerfMiniHUD", "MapOverlayToolbar",
		"CountryActionBar", "MapOverlayLegend", "CountryPanel",
		"WorldLoadingOverlay", "PauseMenu"]
	for node_name in fixed_names:
		_expect("player UI has static %s" % node_name, ui.has_node(node_name))
	var fixed_count := ui.get_child_count()
	root.add_child(scene)
	await process_frame
	var expected_count := fixed_count + (1 if GameUIManager.gm_available_for_build(
		OS.is_debug_build(), Engine.is_editor_hint()) else 0)
	_expect("player UI does not duplicate fixed nodes", ui.get_child_count() == expected_count)
	scene.queue_free()
	await process_frame


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
