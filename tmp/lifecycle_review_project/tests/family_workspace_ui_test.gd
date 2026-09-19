extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	_check_view_model_contract(failures)
	await _check_workspace_interaction(failures)
	if failures.is_empty():
		print("[family-workspace-ui] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[family-workspace-ui] FAIL: %s" % failure)
		quit(1)


func _check_view_model_contract(failures: PackedStringArray) -> void:
	var family_theme := load("res://assets/themes/family_workspace_theme.tres") as Theme
	if family_theme == null or family_theme.default_font_size < 17:
		failures.append("family workspace typography fell below the readable size floor")
	elif not family_theme.default_font is FontVariation or \
			(family_theme.default_font as FontVariation).variation_embolden < 0.15:
		failures.append("family workspace body font is not explicitly emboldened")
	if family_theme != null:
		var card_style := family_theme.get_stylebox(&"panel", &"FamilyCard")
		var summary_style := family_theme.get_stylebox(&"panel", &"FamilySummaryBand")
		if not card_style is StyleBoxTexture or not summary_style is StyleBoxTexture:
			failures.append("family cards lost their bitmap nine-patch treatment")
		else:
			var card_texture := (card_style as StyleBoxTexture).texture
			if card_texture == null or card_texture.get_width() > 1024 \
					or (card_style as StyleBoxTexture).get_texture_margin(SIDE_LEFT) > 26.0:
				failures.append("family card bitmap was not cropped/downsampled for compact corners")
	var fog_map := MapData.new(1, 1)
	fog_map.visible_arr = PackedByteArray([0])
	fog_map.explored_arr = PackedByteArray([1])
	var fog_cell := HexCell.new(0, 0)
	fog_cell.index = 0
	var fog_view_model := CellInspectorViewModel.new()
	fog_view_model.set_context(fog_map, null, null, null, 0.42, 22.0)
	if not fog_view_model.build_family_detail(fog_cell,
			{"kind": "family", "row_id": "family_17"}).is_empty():
		failures.append("explored-but-not-visible cell bypassed family detail fog gate")
	var model := CellInspectorViewModel.family_workspace_model({
		"kind": "family", "row_id": "family_17", "name": "白桥堡曾氏",
		"subtitle": "家族 · 区域 30, 30 · 新征家",
		"row": {
			"family_handle": 17, "population": "5.15万", "net_worth": "51.5万",
			"owned_buildings": "24", "founded_day": 0,
			"prestige_level": 4, "prestige_score_q16": 58982,
			"trait_rows": [
				{"id": "steady", "name": "稳固", "core": true, "value": "核心特性", "detail": "忠诚度 +20%", "effect_summary": "忠诚度 +20%"},
				{"id": "steady", "name": "稳固", "core": true, "value": "核心特性", "detail": "忠诚度 +20%", "effect_summary": "忠诚度 +20%"},
				{"id": "keeper", "name": "守护者", "core": false, "value": "附加特性"},
			],
			"behavior_rows": [
				{"id": "3:tea", "name": "茶", "axis": 3, "axis_name": "商品消费", "factor_percent": 42.0, "factor_text": "42.0%", "deviation": 58.0},
				{"id": "0:farm:legacy", "name": "农庄", "axis": 0, "axis_name": "投资", "factor_percent": 115.0, "factor_text": "115.0%", "deviation": 15.0},
				{"id": "0:farm", "name": "农庄", "axis": 0, "axis_name": "投资", "factor_percent": 172.0, "factor_text": "172.0%", "deviation": 72.0},
			],
			"effect_rows": [
				{"id": "effect:4:a", "kind": "effect", "cell": 4, "name": "丰收"},
				{"id": "effect:9:a", "kind": "effect", "cell": 9, "name": "丰收"},
			],
			"notable_person_rows": [],
			"branch_rows": [{"id": "branch:4", "cell": 4}],
		},
	})
	if model.is_empty() or int(model.get("actions", {}).get("family_handle", 0)) != 17:
		failures.append("family workspace model did not preserve family identity")
	var summary: Array = model.get("summary", [])
	if summary.size() != 4 or String(summary[0].get("value", "")) != "5.15万" \
			or String(summary[1].get("value", "")) != "51.5万":
		failures.append("Chinese compact values were not preserved in summary")
	var preferences: Array = model.get("pages", {}).get("preferences", [])
	if preferences.size() != 2 or int(preferences[0].get("axis", -1)) != 0:
		failures.append("preferences were not grouped in semantic axis order")
	elif not is_equal_approx(float(preferences[0].get("factor_percent", 0.0)), 172.0):
		failures.append("duplicate preference rows did not retain the strongest deviation")
	var traits: Array = model.get("pages", {}).get("traits", [])
	if traits.size() != 2 or not String(traits[0].get("effect_summary", "")).is_empty():
		failures.append("duplicate traits or duplicate detail/effect text were not collapsed")
	var overview: Dictionary = model.get("pages", {}).get("overview", {})
	if String((overview.get("preferences", []) as Array)[0].get("name", "")) != "农庄":
		failures.append("overview did not select the greatest baseline deviation")
	var effects: Array = model.get("pages", {}).get("effects", [])
	if effects.size() != 2 or int(effects[0].get("cell", -1)) == int(effects[1].get("cell", -1)):
		failures.append("same-name effects on different branches were collapsed")
	if not (model.get("pages", {}).get("people", []) as Array).is_empty():
		failures.append("empty notable-person state was not preserved")


func _check_workspace_interaction(failures: PackedStringArray) -> void:
	var host := Control.new()
	host.size = Vector2(960.0, 680.0)
	get_root().add_child(host)
	var workspace := (load("res://scenes/ui/family_workspace.tscn") as PackedScene) \
		.instantiate() as FamilyWorkspace
	host.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.show_family(_sample_model(), false)
	await process_frame
	var overview_effect_card := workspace.get_node("%PageHost").find_child(
		"OverviewEffects", true, false) as PanelContainer
	if overview_effect_card == null:
		failures.append("overview effect card was not built")
	else:
		var effect_grid := overview_effect_card.find_child(
			"OverviewEffectsGrid", true, false) as GridContainer
		if effect_grid == null or effect_grid.get_child_count() != 4:
			failures.append("overview effect grid did not retain all effect rows")
		if effect_grid != null:
			for item_root in effect_grid.get_children():
				var effect_name := (item_root as Control).find_child("Name", true, false) as Label
				if effect_name == null or effect_name.text_overrun_behavior != TextServer.OVERRUN_TRIM_ELLIPSIS:
					failures.append("long overview effect title can overflow its grid cell")
					break
	if workspace.get_viewport().gui_get_focus_owner() != workspace.get_node("%NavOverview"):
		failures.append("family workspace did not assign an initial keyboard focus")
	var page_area := workspace.get_node("SafeMargin/Main/PageArea") as Control
	var local_left := page_area.global_position.x - workspace.global_position.x
	var viewport_width := workspace.get_viewport_rect().size.x
	if workspace.size.x >= viewport_width * 0.75:
		var visual_scale := clampf(minf(workspace.size.x / 855.0,
			workspace.size.y / 876.0), 0.78, 1.5)
		var expected_left := 20.0 * visual_scale + clampf(
			workspace.size.x * 0.21, 126.0 * visual_scale, 300.0) \
			+ 24.0 * visual_scale
		if absf(local_left - expected_left) > 2.0:
			failures.append("full-width workspace did not inset content past the book spine")
	var active_nav_label := workspace.get_node("%NavOverview/Visual").get_child(1) as Label
	if active_nav_label.get_theme_constant("outline_size") < 2:
		failures.append("active family navigation label lacks a contrast outline")
	if workspace.current_page() != "overview" or workspace.cached_page_count() != 1:
		failures.append("workspace did not lazily build the overview page")
	var overview_page := workspace.get_node("%PageHost").get_child(0) as Control
	if overview_page == null or overview_page.get_node_or_null("BottomSafeSpacer") == null:
		failures.append("family page lacks bottom scroll safe space")
	for page_id in ["traits", "preferences", "effects", "people", "branches"]:
		workspace.select_page(page_id, false)
		await process_frame
	if workspace.cached_page_count() != 6:
		failures.append("six-page navigation did not cache all page roots")
	workspace.select_page("preferences", false)
	await process_frame
	var scroll := workspace.get_node("%PageScroll") as ScrollContainer
	_check_page_horizontal_bounds(workspace, failures)
	scroll.scroll_vertical = 60
	await process_frame
	workspace.select_page("traits", false)
	workspace.select_page("preferences", false)
	await process_frame
	if scroll.scroll_vertical != 60:
		failures.append("page scroll position was not restored")
	var before_count := workspace.content_node_count()
	var refreshed := _sample_model()
	refreshed.header.prestige_progress_text = "91.0%"
	refreshed.pages.preferences[0].factor_percent = 133.0
	refreshed.pages.preferences[0].factor_text = "133.0%"
	workspace.set_model(refreshed)
	await process_frame
	if workspace.content_node_count() != before_count \
			or workspace.current_page() != "preferences":
		failures.append("same-shape refresh rebuilt nodes or reset the current page")
	host.size.x = 700.0
	workspace.set_fullscreen_mode(true)
	await process_frame
	if not workspace.compact_navigation():
		failures.append("workspace did not fold navigation below 720px")
	host.size.x = 960.0
	await process_frame
	if workspace.compact_navigation():
		failures.append("workspace did not restore vertical navigation at wide width")
	host.queue_free()
	await process_frame


func _check_page_horizontal_bounds(workspace: FamilyWorkspace,
		failures: PackedStringArray) -> void:
	var scroll := workspace.get_node("%PageScroll") as ScrollContainer
	var scroll_rect := scroll.get_global_rect()
	for card in workspace.find_children("*", "PanelContainer", true, false):
		var panel := card as PanelContainer
		if not panel.is_visible_in_tree() or panel.theme_type_variation != &"FamilyCard":
			continue
		var card_rect := panel.get_global_rect()
		if card_rect.position.x < scroll_rect.position.x - 1.0 or \
				card_rect.end.x > scroll_rect.end.x + 1.0:
			failures.append("family card escaped the horizontal page viewport")
			return


func _sample_model() -> Dictionary:
	var preferences: Array = []
	for index in range(14):
		preferences.append({
			"id": "0:item_%d" % index, "name": "产业 %d" % index,
			"axis": 0, "axis_name": "投资", "factor_percent": 110.0 + index,
			"factor_text": "%.1f%%" % (110.0 + index), "deviation": 10.0 + index,
		})
	return {
		"kind": "family_workspace", "row_id": "family_17",
		"header": {"name": "白桥堡曾氏", "subtitle": "家族 · 区域 30, 30 · 新征家", "prestige_label": "IV", "prestige_progress_text": "89.0%"},
		"summary": [
			{"label": "本家族人口", "value": "5.15万", "icon": "family.metric.population"},
			{"label": "净资产", "value": "51.5万", "icon": "family.metric.wealth"},
			{"label": "产业数", "value": "24", "icon": "family.metric.buildings"},
			{"label": "创立时间", "value": "第0日", "icon": "family.metric.time"},
		],
		"pages": {
			"overview": {"traits": [], "preferences": preferences.slice(0, 4), "effects": [
				{"id": "effect:4:harvest", "kind": "effect", "cell": 4,
					"title": "地块 1753 · 时代鼓舞 · 威望 IV · 资源转化效率提高8%",
					"value": "当地产业持续获得资源转化效率与产量加成"},
				{"id": "effect:5:harvest", "kind": "effect", "cell": 5,
					"title": "地块 1754 · 时代鼓舞 · 威望 IV · 资源转化效率提高8%",
					"value": "当地产业持续获得资源转化效率与产量加成"},
				{"id": "effect:6:harvest", "kind": "effect", "cell": 6,
					"title": "地块 1755 · 时代鼓舞 · 威望 IV · 资源转化效率提高8%",
					"value": "当地产业持续获得资源转化效率与产量加成"},
				{"id": "effect:7:harvest", "kind": "effect", "cell": 7,
					"title": "地块 1756 · 时代鼓舞 · 威望 IV · 资源转化效率提高8%",
					"value": "当地产业持续获得资源转化效率与产量加成"}],
				"people": []},
			"traits": [{"id": "steady", "name": "稳固", "kind_label": "核心特性", "detail": "家族成员忠诚度自然提升。", "effect_summary": "忠诚度 +55.7%"}],
			"preferences": preferences,
			"effects": [{"id": "effect:4:harvest", "kind": "effect", "cell": 4, "title": "丰收", "value": "产量 +20%", "detail": "当地产业持续增产。"}],
			"people": [{"id": "person:8", "name": "曾平", "role": "产业所有者", "profession": "工匠", "building": "纺织作坊"}],
			"branches": [{"id": "branch:4", "cell": 4, "prestige_label": "IV", "prestige_text": "89.0%", "population_share_text": "52.9%", "cash_share_text": "48.0%", "building_share_text": "25.8%", "target_label": "V", "review_streak": 1}],
		},
		"actions": {"family_handle": 17},
	}
