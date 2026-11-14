extends SceneTree

const NarrativeEventCatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const PauseMenuScene := preload("res://scenes/ui/pause_menu.tscn")
const OUTPUT_DIR := "res://tmp/narrative_ui_qa"


## 只给截图用的日历桩：让题头显示「第 N 年 · M 月 D 日」而不是兜底的「第 N 日」。
class ClockStub extends RefCounted:
	const DAYS_PER_YEAR := 360
	const DAYS_PER_MONTH := 30
	func days_per_year() -> int:
		return DAYS_PER_YEAR
	func year_index_for_day(day: int) -> int:
		return int(floor(float(day) / float(DAYS_PER_YEAR)))
	func calendar_date_for_day(day: int) -> Dictionary:
		var day_of_year := int(day) % DAYS_PER_YEAR
		return {
			"month": int(floor(float(day_of_year) / float(DAYS_PER_MONTH))) + 1,
			"day_of_month": day_of_year % DAYS_PER_MONTH + 1,
		}


func _init() -> void:
	call_deferred("_run")


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

	var catalog := NarrativeEventCatalogScript.build_default_catalog()
	var service := NarrativeEventServiceScript.new()
	service.configure(null, null, null, ClockStub.new(), 1, 77777, catalog)

	var dialog := NarrativeEventDialogScript.new()
	root.add_child(dialog)
	dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var chron := NarrativeChroniclePanelScript.new()
	root.add_child(chron)
	chron.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 1. Event Offer Modal (calendar-only kicker, probabilistic outcomes)
	var chain1 := catalog.get_event(&"evt.chain.strange_outcrop")
	var offer_chain := service.enqueue_event_offer(chain1, 7, 40, &"chain_strange_outcrop", true, {
		"cell_idx": 7,
		"settlement_name": "铜官山",
		"landform_name": "丘陵",
		"temperature": 19.2,
		"treasury_cash": 400000,
	})
	service.choose_option(int(offer_chain.get("offer_id", 0)), int(offer_chain.get("offer_generation", 0)), 0, 41)

	var drought := catalog.get_event(&"evt.climate.severe_drought")
	var offer := service.enqueue_event_offer(drought, 12, 85, &"", true, {
		"cell_idx": 12,
		"settlement_name": "云梦泽畔·新郑",
		"landform_name": "冲积平原",
		"terrain_name": "农田",
		"temperature": 33.4,
		"treasury_cash": 350000,
	})
	dialog.present_offer(offer)
	await _save_shot(out_abs.path_join("1_narrative_event_offer.png"))

	# 2. Rolled Outcome Resolution View
	var res := service.choose_option(int(offer.get("offer_id", 0)), int(offer.get("offer_generation", 0)), 0, 86)
	dialog.show_outcome(res)
	await _save_shot(out_abs.path_join("2_narrative_event_outcome.png"))
	dialog.close_offer()

	# 3. Chronicle History Panel
	chron.open_panel(service.get_chronicle())
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
	quit(0)


func _save_shot(abs_path: String) -> void:
	await create_timer(0.55).timeout
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(abs_path)
