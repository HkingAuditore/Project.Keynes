extends SceneTree

## Family founding 1-of-3 dialog plus the PlayerController modal lock:
## Left dossier summaries, one expanded house, plain buff copy, inspector
## avoidance, queued-offer animation safety, and the existing clock lock.

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

class ClockStub:
	var paused := false
	var speed_multiplier := 4.0

	func pause(value: bool) -> void:
		paused = value

	func set_speed(value: float) -> void:
		speed_multiplier = value

	func day_index() -> int:
		return 12

	func year_index() -> int:
		return 0

	func calendar_date() -> Dictionary:
		return {"month": 1, "day_of_month": 13}


class UiStub:
	var shown: Dictionary = {}
	var open := false
	var closed_count := 0

	func update_time_state(_year: int, _month: int, _day: int, _paused: bool,
			_speed: float) -> void:
		pass

	func show_family_founding_offer(offer: Dictionary) -> void:
		shown = offer
		open = true

	func close_family_founding_offer() -> void:
		open = false
		closed_count += 1

	func is_family_founding_modal_open() -> bool:
		return open

	func show_family_founding_error(_message: String) -> void:
		pass


class FacadeStub:
	var offers: Array = []

	func family_founding_offers(_offset: int = 0, _limit: int = 16) -> Dictionary:
		return {"ok": true, "total": offers.size(), "offers": offers}


var _failures := PackedStringArray()
var _choice := [-1, -1, -1]
var _located_cell := -99


func _initialize() -> void:
	call_deferred("_run")


func _card(name: String, building: String, effect: String) -> Dictionary:
	return {
		"stable_id": name.hash(),
		"family_name": name,
		"building_display_name": building,
		"owner_profession_display_name": "采集者",
		"founders": 42,
		"trait_display_names": PackedStringArray(["节俭", "采集"]),
		"trait_descriptions": PackedStringArray(["日常消费减少 10%", "投资采集类建筑的可能性增加 50%"]),
		"effect_display_name": effect,
		"effect_description": "当前未达威望Ⅰ。",
		"effect_prestige_descriptions": PackedStringArray([
			"威望Ⅰ：本地块产出提高 2%。",
			"威望Ⅱ：本地块产出提高 4%。",
			"威望Ⅲ：本地块产出提高 6%。",
			"威望Ⅳ：本地块产出提高 8%。",
			"威望Ⅴ：本地块产出提高 10%。",
		]),
	}


func _run() -> void:
	var dialog := (load("res://scenes/ui/family/family_founding_dialog.tscn")
		as PackedScene).instantiate() as FamilyFoundingDialog
	root.add_child(dialog)
	await process_frame
	dialog.choice_requested.connect(func(offer_id: int, generation: int, index: int) -> void:
		_choice = [offer_id, generation, index])
	dialog.locate_cell_requested.connect(func(cell_idx: int) -> void:
		_located_cell = cell_idx)
	dialog.present_offer({
		"offer_id": 9,
		"generation": 3,
		"cell": 17,
		"settlement_name": "长安",
		"milestone_population": 200,
		"cell_population": 216,
		"queue_remaining": 1,
		"candidates": [
			_card("长安张氏", "采集营地", "专精产业"),
			_card("长安李氏", "狩猎营地", "远亲"),
		],
	})
	await process_frame
	var cards := dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/CardsScroll/CardGrid")
	_expect("dialog opens with three card slots", dialog.visible
		and dialog.is_offer_open() and cards.get_child_count() == 3)
	_expect("dialog root passes mouse outside floating dossier and hides fullscreen book background",
		dialog.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and not (dialog.get_node("ArchiveSurface/PaperBackground") as Control).visible)
	var first := cards.get_child(0) as FamilyFoundingCard
	var third := cards.get_child(2) as FamilyFoundingCard
	_expect("summary shows name, origin, founder count, trait keywords and first prestige effect",
		String((first.get_node("%Title") as Label).text) == "长安张氏"
		and String((first.get_node("%Origin") as Label).text).contains("采集营地")
		and String((first.get_node("%Origin") as Label).text).contains("42")
		and String((first.get_node("%TraitSummary") as Label).text).contains("节俭")
		and String((first.get_node("%EffectPreview") as Label).text).contains("专精产业"))
	_expect("all details start collapsed, all three summaries remain in one column",
		not first.is_details_expanded() and not third.is_details_expanded()
		and (cards as GridContainer).columns == 1)
	_expect("buff copy has no progress bars or duplicate numeric pills",
		first.find_children("*", "ProgressBar", true, false).is_empty()
		and (first.get_node("%TraitsList") as VBoxContainer).get_child_count() == 2)
	var effect_preview := String((first.get_node("%EffectPreview") as Label).text)
	_expect("effect preview shows Prestige I statement instead of unreached-prestige placeholder",
		effect_preview.contains("威望Ⅰ：本地块产出提高 2%")
		and not effect_preview.contains("当前未达威望"))
	first.details_button().emit_signal("pressed")
	await create_timer(0.22).timeout
	_expect("details show complete trait copy and five prestige tiers without submitting",
		first.is_details_expanded()
		and (first.get_node("%DetailsClip") as Control).visible
		and (first.get_node("%EffectTiersBox") as Control).get_child_count() == 5
		and _choice == [-1, -1, -1])
	_expect("expanded text uses the full card width",
		absf((first.get_node("%DetailsContent") as Control).size.x
			- (first.get_node("%DetailsClip") as Control).size.x) <= 1.0)
	var second := cards.get_child(1) as FamilyFoundingCard
	second.details_button().emit_signal("pressed")
	await create_timer(0.22).timeout
	_expect("opening another house collapses its predecessor and preserves three summaries",
		not first.is_details_expanded() and second.is_details_expanded()
		and cards.get_child_count() == 3)
	var existing_card_id := first.get_instance_id()
	var old_scroll := (dialog.get_node("%CardsScroll") as ScrollContainer).scroll_vertical
	dialog.present_offer({"offer_id": 9, "generation": 3})
	_expect("same offer refresh preserves nodes, expanded house and scroll",
		first.get_instance_id() == existing_card_id and second.is_details_expanded()
		and (dialog.get_node("%CardsScroll") as ScrollContainer).scroll_vertical == old_scroll)
	_expect("prompt explains the settlement milestone and consequence",
		String(dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text").text).contains("长安人口已达 200")
		and String(dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text").text).contains("其余两户"))
	var locate_btn := dialog.get_node("%LocateButton") as Button
	locate_btn.emit_signal("pressed")
	_expect("locate button emits cell index for map/inspector focus", _located_cell == 17)
	dialog.toggle_collapsed()
	_expect("collapse mode hides body to reveal map and shrinks height",
		dialog.is_collapsed()
		and not (dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body") as Control).visible
		and (dialog.get_node("%CollapsedEntry") as Control).visible
		and (dialog.get_node("%CollapsedEntry") as Control).size.y <= 50.0)
	dialog.toggle_collapsed()
	_expect("expanding restores body and card grid",
		not dialog.is_collapsed()
		and second.is_details_expanded()
		and (dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body") as Control).visible)
	dialog.set_inspector_obscures(true)
	_expect("large inspector temporarily collapses founding panel", dialog.is_collapsed())
	dialog.set_inspector_obscures(false)
	_expect("closing inspector restores expanded house", not dialog.is_collapsed() and second.is_details_expanded())
	dialog.set_collapsed(true, false)
	dialog.set_inspector_obscures(true)
	dialog.set_inspector_obscures(false)
	_expect("manual collapse survives large inspector open and close", dialog.is_collapsed())
	dialog.set_collapsed(false, false)
	for res in [Vector2(1280.0, 720.0), Vector2(1366.0, 768.0), Vector2(1920.0, 1080.0), Vector2(2560.0, 1440.0)]:
		var safe := Rect2(Vector2(52.0, 52.0), Vector2(res.x - 52.0 - 460.0, res.y - 104.0))
		dialog.set_safe_area(safe)
		var surface := dialog.get_node("ArchiveSurface") as Control
		_expect("floating dossier avoids right 460px inspector at %dx%d" % [int(res.x), int(res.y)],
			absf(surface.position.x - safe.position.x - UITokens.SPACE_SM) <= 1.0
			and surface.size.x <= UITokens.FAMILY_FOUNDING_WIDE_WIDTH
			and surface.position.x + surface.size.x <= res.x - 460.0 + 1.0)
	_expect("missing third candidate disables only its button",
		not first.choose_button().disabled and third.choose_button().disabled)
	_expect("first available choice takes keyboard focus",
		first.details_button().has_focus())
	second.choose_button().emit_signal("pressed")
	_expect("choice carries offer id, generation and index", _choice == [9, 3, 1])
	first.choose_button().emit_signal("pressed")
	_expect("repeated input cannot overwrite pending choice", _choice == [9, 3, 1])
	_expect("pending state disables every choice",
		first.choose_button().disabled
		and (cards.get_child(1) as FamilyFoundingCard).choose_button().disabled)
	dialog.show_error("候选已过期")
	_expect("error re-enables valid choices and keeps a readable status",
		not first.choose_button().disabled and third.choose_button().disabled
		and String(dialog.get_node(
			"ArchiveSurface/Frame/Margin/Column/Body/Status").text).find("候选已过期") >= 0)
	dialog.close_offer()
	_expect("close hides the dialog", not dialog.is_offer_open())
	dialog.present_offer({"offer_id": 10, "generation": 1,
		"candidates": [_card("新城王氏", "伐木场", "多子多福")]})
	await create_timer(0.2).timeout
	_expect("old close callback cannot hide the next queued offer",
		dialog.is_offer_open() and dialog.visible and dialog.current_offer_id() == 10)
	var long_card := _card("新城张氏繁衍兴盛产业广布四方之家", "跨地区联合经营狩猎采集营地", "狩猎与采集产业经营者")
	var split_card := _card("洛阳陈氏 · 方案一", "采集营地", "勤勉持家")
	split_card["people_label"] = "分支族人"
	split_card["choice_label"] = "确立此家风"
	split_card["choice_tooltip"] = "将本地整支族人、产业与名人统一转入新家族。"
	dialog.present_offer({"offer_id": 12, "generation": 1, "kind": "SPLIT",
		"settlement_name": "洛阳", "source_family_name": "雅典陈氏",
		"candidates": [split_card, split_card.duplicate(true), split_card.duplicate(true)]})
	var split_prompt := String(dialog.get_node("ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text").text)
	_expect("split proposal explains surname, whole-branch transfer and the continuing parent",
		split_prompt.contains("保留原姓氏") and split_prompt.contains("本地整支")
		and split_prompt.contains("其他城市继续存在"))
	_expect("split cards show branch people and a distinct confirmation action",
		(first.get_node("%Origin") as Label).text.contains("分支族人")
		and first.choose_button().text == "确立此家风")
	long_card["trait_display_names"] = PackedStringArray(["节俭持家", "采集产业专精", "勤勉从业", "开拓门风"])
	long_card["trait_descriptions"] = PackedStringArray(["日常消费减少 10%。", "投资相关产业的可能性增加 50%。",
		"更倾向选择当地已经存在或解锁的合法职业。", "更倾向参与开拓并寻找新的发展机会。"])
	dialog.set_safe_area(Rect2(Vector2(88.0, 76.0), Vector2(700.0, 540.0)))
	dialog.present_offer({"offer_id": 11, "generation": 1,
		"settlement_name": "沿河多产业联合发展与贸易枢纽城市", "candidates": [long_card, long_card]})
	first.details_button().pressed.emit()
	second.details_button().pressed.emit()
	first.details_button().pressed.emit()
	await create_timer(0.25).timeout
	_expect("rapid details switching leaves exactly the last house expanded",
		first.is_details_expanded() and not second.is_details_expanded())
	var surface := dialog.get_node("ArchiveSurface") as Control
	var frame := dialog.get_node("ArchiveSurface/Frame") as Control
	_expect("long city, house and industry names wrap within panel width",
		frame.get_global_rect().end.x <= surface.get_global_rect().end.x + 1.0
		and first.get_global_rect().end.x <= surface.get_global_rect().end.x + 1.0)
	_expect("four full traits remain accessible in expanded details",
		(first.get_node("%TraitsList") as VBoxContainer).get_child_count() == 4)
	dialog.close_offer()
	await create_timer(0.2).timeout
	if OS.get_environment("PK_CAPTURE_FOUNDING_QA") == "1":
		await _capture_visual_qa()
	dialog.queue_free()
	_test_facade_card_decoration()
	_test_controller_lock()
	print("family founding dialog ui: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _test_facade_card_decoration() -> void:
	var facade := EconomyFacade.new()
	facade._building_display_names = {"gathering_ground": "采集营地"}
	facade._profession_display_names = {"forager": "采集者"}
	facade._load_family_effect_displays()
	var card := {
		"surname": "孟",
		"culture_group_naming_format": "CITY_SURNAME_SUFFIX",
		"culture_group_separator": "·",
		"culture_group_suffix": "氏",
		"building_type_id": "gathering_ground",
		"owner_profession_id": "forager",
		"founders": 50,
		"trait_keys": PackedStringArray(["c003_vegetarian"]),
		"trait_strength_q16": PackedInt32Array([18000]),
		"effect_key": "birth_plenty",
	}
	facade._decorate_family_founding_card(card, "洛阳")
	var effect_desc := String(card.get("effect_description", ""))
	var prestige_list: PackedStringArray = card.get(
		"effect_prestige_descriptions", PackedStringArray())
	var trait_items: Array = card.get("trait_items", [])
	_expect("facade decorates founding card with Prestige I effect and 5-tier list",
		String(card.get("effect_display_name", "")) == "多子多福"
		and effect_desc.find("威望Ⅰ") >= 0
		and effect_desc.find("当前未达威望") < 0
		and prestige_list.size() == 5)
	_expect("facade decorates founding card with structured trait items and icons",
		not String(card.get("building_icon_key", "")).is_empty()
		and not String(card.get("profession_icon_key", "")).is_empty()
		and trait_items.size() == 1
		and ((trait_items[0] as Dictionary).get("badges", []) as Array).size() >= 1)


func _test_controller_lock() -> void:
	var controller = PlayerControllerScript.new()
	var clock := ClockStub.new()
	var ui := UiStub.new()
	var facade := FacadeStub.new()
	controller._world_clock = clock
	controller._ui_manager = ui
	controller._economy_facade = facade
	facade.offers = [
		{"offer_id": 4, "generation": 1, "status": "OPEN", "player_choice": true,
			"candidates": [{}, {}, {}]},
		{"offer_id": 5, "generation": 1, "status": "OPEN", "player_choice": false,
			"candidates": [{}, {}, {}]},
	]
	controller._sync_family_founding_offer()
	_expect("open player offer locks the session and pauses the clock",
		controller.family_founding_locked() and clock.paused and ui.open
		and int(ui.shown.get("offer_id", 0)) == 4)
	_expect("non-player offers are never presented",
		int(ui.shown.get("queue_remaining", -1)) == 0)
	var blocked: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_SET_BUDGET,
		{"enabled": true, "daily_cash_limit": 1})
	_expect("other player commands wait for the founding choice",
		String(blocked.get("code", "")) == "family_founding_choice_required")
	var stale: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_FAMILY_FOUNDING_CHOOSE,
		{"offer_id": 99, "generation": 1, "choice_index": 0})
	_expect("choice for a different offer is rejected before the runtime",
		String(stale.get("code", "")) != "family_founding_choice_required"
		and not bool(stale.get("ok", true)))
	controller._on_pause_toggled(false)
	_expect("unpausing is ignored while the founding pick is open", clock.paused)
	var saved: Dictionary = controller.capture_view_state()
	_expect("view state records the founding lock and resume speed",
		bool(saved.get("family_founding_locked", false))
		and bool(saved.get("family_founding_resume_running", false))
		and is_equal_approx(float(saved.get("family_founding_previous_speed", 0.0)), 4.0))
	facade.offers[0]["status"] = "SELECTED_PENDING"
	controller._sync_family_founding_offer()
	_expect("settled choice unlocks and resumes at the previous speed",
		not controller.family_founding_locked() and not clock.paused
		and is_equal_approx(clock.speed_multiplier, 4.0) and not ui.open)
	controller.free()


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("  [FAIL] %s" % label)


func _capture_visual_qa() -> void:
	var out_dir := "res://tmp/family_founding_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var facade := EconomyFacade.new()
	facade._building_display_names = {
		"gathering_ground": "采集营地",
		"lumber_camp": "伐木场",
		"hunting_ground": "狩猎采集营地",
	}
	facade._profession_display_names = {
		"forager": "采集者",
		"forestry_worker": "伐木工",
		"hunter": "猎人",
	}
	facade._load_family_effect_displays()
	var c0 := {
		"surname": "孟",
		"culture_group_naming_format": "CITY_SURNAME_SUFFIX",
		"culture_group_separator": "·",
		"culture_group_suffix": "氏",
		"building_type_id": "gathering_ground",
		"owner_profession_id": "forager",
		"founders": 50,
		"trait_keys": PackedStringArray(["c001_gluttony", "c003_vegetarian"]),
		"trait_strength_q16": PackedInt32Array([20000, 18000]),
		"effect_key": "birth_plenty",
	}
	var c1 := {
		"surname": "王",
		"culture_group_naming_format": "CITY_SURNAME_SUFFIX",
		"culture_group_separator": "·",
		"culture_group_suffix": "氏",
		"building_type_id": "lumber_camp",
		"owner_profession_id": "forestry_worker",
		"founders": 50,
		"trait_keys": PackedStringArray(["c002_carnivore", "c003_vegetarian"]),
		"trait_strength_q16": PackedInt32Array([22000, 16000]),
		"effect_key": "birth_decline",
	}
	var c2 := {
		"surname": "邓",
		"culture_group_naming_format": "CITY_SURNAME_SUFFIX",
		"culture_group_separator": "·",
		"culture_group_suffix": "氏",
		"building_type_id": "hunting_ground",
		"owner_profession_id": "hunter",
		"founders": 50,
		"trait_keys": PackedStringArray(["c001_gluttony", "c002_carnivore"]),
		"trait_strength_q16": PackedInt32Array([15000, 24000]),
		"effect_key": "birth_plenty",
	}
	facade._decorate_family_founding_card(c0, "洛阳")
	facade._decorate_family_founding_card(c1, "洛阳")
	facade._decorate_family_founding_card(c2, "洛阳")
	var sample_offer := {
		"offer_id": 11,
		"generation": 1,
		"cell": 42,
		"settlement_name": "洛阳",
		"milestone_population": 100,
		"cell_population": 128,
		"queue_remaining": 1,
		"candidates": [c0, c1, c2],
	}
	var split_qa := OS.get_environment("PK_CAPTURE_SPLIT_QA") == "1"
	if split_qa:
		sample_offer["kind"] = "SPLIT"
		sample_offer["source_family_name"] = "雅典陈氏"
		for i in 3:
			var card: Dictionary = sample_offer.candidates[i]
			card["family_name"] = "洛阳陈氏 · 方案%s" % ["一", "二", "三"][i]
			card["people_label"] = "分支族人"
			card["choice_label"] = "确立此家风"
	var session_theme := load("res://assets/themes/player_session_theme.tres") as Theme
	for viewport_size in [Vector2i(1920, 1080), Vector2i(1366, 768), Vector2i(1280, 720), Vector2i(2560, 1440)]:
		var vp := SubViewport.new()
		vp.size = viewport_size
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		root.add_child(vp)
		var host := Control.new()
		host.size = Vector2(viewport_size)
		host.theme = session_theme
		vp.add_child(host)
		var map_bg := ColorRect.new()
		map_bg.size = Vector2(viewport_size)
		map_bg.color = Color(0.24, 0.31, 0.25, 1.0)
		host.add_child(map_bg)
		var top_bar := PanelContainer.new()
		top_bar.position = Vector2.ZERO
		top_bar.size = Vector2(viewport_size.x, 48.0)
		top_bar.theme_type_variation = &"PKHUDPanel"
		host.add_child(top_bar)
		var inspector := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene).instantiate() as InspectorPanel
		host.add_child(inspector)
		inspector.visible = true
		inspector.position = Vector2(viewport_size.x - 460.0, 56.0)
		inspector.size = Vector2(460.0, viewport_size.y - 68.0)
		inspector.set_model_for_selection({
			"header": {"kicker": "地块档案 · #42", "title": "洛阳（温带冲积平原）", "subtitle": "海拔 120m · 湿润 · 森林草甸"},
			"summary_cards": [
				{"label": "总人口", "value": "128"},
				{"label": "在营建筑", "value": "3"},
				{"label": "主要资源", "value": "林木/耕地"},
				{"label": "粮食满足", "value": "94%"},
			],
			"tabs": [
				{"id": "geography", "label": "地理"},
				{"id": "resources", "label": "自然资源"},
				{"id": "market", "label": "市场"},
				{"id": "buildings", "label": "建筑"},
				{"id": "population", "label": "人口"},
			],
			"categories": {
				"geography": {
					"metrics": [
						{"id": "terrain", "label": "地形地貌", "value": "冲积平原 · 森林"},
						{"id": "temp", "label": "年均气温", "value": "15.4 °C"},
						{"id": "rain", "label": "有效水分", "value": "74%"},
						{"id": "river", "label": "水文条件", "value": "大河干流经过"},
					],
					"notes": ["本地块林木与野生植物储量充沛，适宜采集、伐木或垦殖立族。"],
				}
			}
		})
		var dlg := (load("res://scenes/ui/family/family_founding_dialog.tscn") as PackedScene).instantiate() as FamilyFoundingDialog
		host.add_child(dlg)
		var safe := Rect2(Vector2(52.0, 56.0), Vector2(viewport_size.x - 52.0 - 460.0, viewport_size.y - 104.0))
		dlg.set_safe_area(safe)
		dlg.present_offer(sample_offer)
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var out_path := "%s/founding_%dx%d.png" % [out_dir, viewport_size.x, viewport_size.y]
		if split_qa:
			out_path = out_path.replace("/founding_", "/split_")
		if img != null and not img.is_empty():
			img.save_png(out_path)
			print("[founding-qa] %s" % ProjectSettings.globalize_path(out_path))
		if viewport_size == Vector2i(1920, 1080):
			var card0 := dlg.get_node("ArchiveSurface/Frame/Margin/Column/Body/CardsScroll/CardGrid/Card0") as FamilyFoundingCard
			if card0 != null:
				card0.details_button().emit_signal("pressed")
				await create_timer(0.25).timeout
				await RenderingServer.frame_post_draw
				var img_tiers := vp.get_texture().get_image()
				var tiers_path := "%s/founding_1920x1080_tiers_open.png" % out_dir
				if img_tiers != null and not img_tiers.is_empty():
					img_tiers.save_png(tiers_path)
					print("[founding-qa] %s" % ProjectSettings.globalize_path(tiers_path))
			dlg.set_collapsed(true, false)
			for _i in 4:
				await process_frame
			await RenderingServer.frame_post_draw
			var img_collapsed := vp.get_texture().get_image()
			var collapsed_path := "%s/founding_1920x1080_collapsed.png" % out_dir
			if img_collapsed != null and not img_collapsed.is_empty():
				img_collapsed.save_png(collapsed_path)
				print("[founding-qa] %s" % ProjectSettings.globalize_path(collapsed_path))
		vp.queue_free()
		await process_frame
