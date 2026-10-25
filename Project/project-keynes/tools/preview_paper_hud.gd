extends SceneTree

var _output := "res://../../artifacts/paper-icons/hud"
var _prefix := "map"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("prefix="):
			_prefix = argument.trim_prefix("prefix=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	var clock := game.get_node("WorldClock") as WorldClock
	clock.paused = true
	await create_timer(1.0).timeout
	await _capture("overview")
	var toolbar := game.get_node("UI/UIRoot/HUDLayer/MapOverlayToolbar") as MapOverlayToolbar
	var categories: Dictionary = toolbar.get("_category_buttons")
	for category in [MapOverlayToolbar.Category.GEOGRAPHY, MapOverlayToolbar.Category.CLIMATE,
			MapOverlayToolbar.Category.RESOURCES]:
		(categories[category] as Button).pressed.emit()
		await create_timer(0.35).timeout
		await _capture(["geography", "climate", "resources"][category-1])
		toolbar.dismiss_submenu()
		await create_timer(0.25).timeout
	runtime.set_fog_of_war_enabled(false)
	(game.get_node("PlayerController") as PlayerController).clear_selection()
	await create_timer(0.5).timeout
	await _capture("terrain_no_fog")
	var ui := game.get_node("UI") as GameUIManager
	for section in ["technology", "ideology", "economy"]:
		ui.open_country_section(section)
		await create_timer(0.4).timeout
		await _capture(section)
		if section == "technology":
			var country_panel := game.get_node("UI/UIRoot/PanelLayer/CountryPanel") as CountryPanel
			var technology_workspace := country_panel.get("_technology_workspace") as Control
			technology_workspace.call("_set_mode", TechnologyWorkspace.MODE_FOCUS)
			await create_timer(0.4).timeout
			await _capture("technology_tree")
		if section == "economy":
			var panel := game.get_node("UI/UIRoot/PanelLayer/CountryPanel") as CountryPanel
			var dossier := panel.get("_economy_dossier") as EconomyDossier
			for chapter in ["finance", "strata"]:
				dossier.select_chapter(chapter)
				await create_timer(0.3).timeout
				await _capture("economy_" + chapter)
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	await create_timer(0.4).timeout
	await _capture("economy_wide")
	game.queue_free()
	await process_frame
	print("[paper-hud-preview] captured formal player game")
	quit()

func _capture(suffix: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var dimensions := root.get_texture().get_size()
	var path := _output.path_join("%s_%s_%dx%d.png" % [_prefix, suffix, dimensions.x, dimensions.y])
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Cannot save HUD capture: %s" % path)
	print("[paper-hud-preview] %s" % ProjectSettings.globalize_path(path))
