extends "res://tests/archive_material_screenshot_qa.gd"

## Uses formal overlay button signals; the toast is a presentation fixture.
const PAPER_OUTPUT := "res://tmp/paper_aux_game_qa"
var _paper_overlay_set := false


func _capture(label: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PAPER_OUTPUT))
	if label == "map_1366x768" and not _paper_overlay_set:
		_paper_overlay_set = true
		var game := root.get_node("PlayerGame")
		var ui := game.get_node("UI") as GameUIManager
		var toolbar := ui.get("_map_overlay_toolbar") as MapOverlayToolbar
		toolbar.call("_set_category", MapOverlayToolbar.Category.GEOGRAPHY)
		var mode_buttons: Array = toolbar.get("_mode_buttons")
		_expect(not mode_buttons.is_empty(), "geography overlay actions exist")
		if not mode_buttons.is_empty():
			(mode_buttons[0] as Button).pressed.emit()
		ui.call("_ensure_research_toast")
		var toast := ui.get("_research_toast") as ResearchToast
		toast.show_research_completed("陶器制作")
		await create_timer(0.35).timeout
		var legend := ui.get("_map_overlay_legend") as OverlayLegend
		_expect(legend.visible, "formal overlay action opens the paper legend")
		_expect(not legend.get_global_rect().intersects(
			(ui.get("_right_panel") as InspectorPanel).get_global_rect()),
			"paper legend leaves the main dossier clear")
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	_expect(shot != null and shot.save_png("%s/%s.png" % [PAPER_OUTPUT, label]) == OK,
		"paper game capture %s" % label)
	print("[paper-game-qa] %s" % label)
