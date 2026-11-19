extends "res://tests/support/runtime_narrative_scenario.gd"

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const PauseMenuScene := preload("res://scenes/ui/pause_menu.tscn")
const OUTPUT_DIR := "res://tmp/narrative_ui_qa"


func _run() -> void:
	var out_abs := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(out_abs)

	root.content_scale_factor = 1.0
	var vp_size := Vector2i(1366, 768)
	root.size = vp_size
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(vp_size)

	# Warm map-style backdrop
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.17, 0.22, 0.19, 1.0)
	root.add_child(bg)

	if not await _start_story({"scheduled_events": [
		{"due_day": 2, "event_id": "evt.chain.strange_outcrop"},
		{"due_day": 4, "event_id": "evt.climate.severe_drought"},
	]}):
		await _close_story()
		quit(1)
		return
	await _advance_story(2)
	_choose_story(0)
	await _advance_story(4)

	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var chron := NarrativeChroniclePanelScript.new()
	root.add_child(chron)
	chron.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	dialog.present_offer(story_service.active_offer())
	await _save_shot(out_abs.path_join("1_narrative_event_offer.png"))
	_choose_story(0)
	await _advance_story(5)
	dialog.show_outcome({"record": _story_records()[0]})
	await _save_shot(out_abs.path_join("2_narrative_event_outcome.png"))
	dialog.close_offer()

	# 3. Chronicle History Panel
	chron.open_panel(_story_records())
	await _save_shot(out_abs.path_join("3_narrative_chronicle_list.png"))
	chron.close_panel()

	# 4. AI configuration lives in game settings now (pause menu), not the event folio.
	var pause_menu = PauseMenuScene.instantiate()
	root.add_child(pause_menu)
	pause_menu.visible = true
	pause_menu._show_settings()
	await _save_shot(out_abs.path_join("4_pause_settings.png"))
	pause_menu._show_ai_settings()
	await _save_shot(out_abs.path_join("5_ai_settings.png"))
	pause_menu.free()

	print("[narrative-ui-qa] saved 5 screenshots to: ", out_abs)
	await _close_story()
	quit(0 if _failures == 0 else 1)


func _save_shot(abs_path: String) -> void:
	await create_timer(0.55).timeout
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(abs_path)
