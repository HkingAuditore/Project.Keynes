extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	var root := Control.new()
	root.size = Vector2(1280.0, 720.0)
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)

	var top_bar := (load("res://scenes/ui/player_top_bar.tscn") as PackedScene).instantiate() as PlayerTopBar
	root.add_child(top_bar)
	top_bar.set_world_summary(60, 40, 2400, 123456)
	top_bar.update_time_state(9, 6, 18, false, 20.0)
	if top_bar._date_label.text != "第10年 · 6月18日":
		failures.append("top bar did not display the current year and calendar date")

	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene).instantiate() as InspectorPanel
	root.add_child(panel)
	panel.visible = true
	await process_frame

	# Components may receive their initial model before the caller adds them to the tree.
	var deferred_picker := (load("res://scenes/ui/construction_picker.tscn") as PackedScene).instantiate() as ConstructionPicker
	deferred_picker.set_model({
		"available": false,
		"message": "测试：尚未拥有该地块。",
	})
	root.add_child(deferred_picker)
	await process_frame
	if deferred_picker._rows == null \
			or deferred_picker._status.text != "测试：尚未拥有该地块。" \
			or not deferred_picker._prev.disabled \
			or not deferred_picker._next.disabled:
		failures.append("construction picker lost a model supplied before entering the scene tree")
	deferred_picker.custom_minimum_size = Vector2(400.0, 240.0)
	deferred_picker.size = Vector2(400.0, 240.0)
	deferred_picker.set_model(_construction_scroll_model())
	await process_frame
	await process_frame
	var construction_scroll := deferred_picker._rows_scroll.get_v_scroll_bar()
	if construction_scroll.max_value <= construction_scroll.page:
		failures.append("construction quote list did not become vertically scrollable")
	var first_option := deferred_picker._rows.get_child(0) as Button
	if first_option == null \
			or String((first_option.get_node(
				"Margin/Line/Info/MaterialsRow/Materials") as Label).text).contains("国库") \
			or not String((first_option.get_node(
				"Margin/Line/Info/MaterialsRow/Materials") as Label).text).contains("单价") \
			or not String((first_option.get_node(
				"Margin/Line/Info/RecipeRow/Recipe") as Label).text).contains("产出") \
			or not String((first_option.get_node(
				"Margin/Line/Info/JobsRow/Jobs") as Label).text).contains("工匠") \
			or first_option.find_children("", "IconBadge", true, false).size() < 4:
		failures.append("construction option did not render the compact icon/material/recipe/job contract")
	var jobs_label := first_option.get_node(
		"Margin/Line/Info/JobsRow/Jobs") as Label
	if jobs_label.get_global_rect().end.y > first_option.get_global_rect().end.y + 0.5:
		failures.append("construction option content is clipped at the 400px detail width")

	var model := _make_model()
	panel.set_model_for_selection(model)
	await process_frame
	await process_frame
	for button in panel._tabs._buttons.values():
		if String((button as Button).text).is_empty():
			failures.append("dossier tab header does not display its short label")
		var icons := (button as Button).find_children("", "IconBadge", true, false)
		if icons.size() != 1 or absf((icons[0] as Control).get_global_rect().get_center().y -
			(button as Control).get_global_rect().get_center().y) > 1.0 \
			or (icons[0] as Control).get_global_rect().get_center().x >= \
				(button as Control).get_global_rect().get_center().x:
			failures.append("dossier tab icon is not aligned before its label: button=%s icon=%s" % [
				(button as Control).get_global_rect(),
				(icons[0] as Control).get_global_rect() if icons.size() == 1 else Rect2()])
	if panel._summary_grid.columns != 2:
		failures.append("dossier summary is not using the compact two-column grid")
	for raw_card in panel._summary_cards.values():
		var summary_card := raw_card as MetricCard
		if summary_card != null and summary_card.size.x < 120.0:
			failures.append("summary cards are too narrow for the compact dossier grid: card=%s grid=%s" % [
				summary_card.size, panel._summary_grid.size])
	var overview_count := panel.visible_node_count()
	var overview_patch := _make_patch("geography")
	panel.apply_live_patch(overview_patch)
	await process_frame
	if panel.visible_node_count() != overview_count:
		failures.append("overview live patch changed inspector node count")
	if panel.current_tab() != "geography":
		failures.append("overview live patch changed current tab")
	var overview_chart := panel._chart_controls.get("overview_ecology_history") as SparklineChart
	if overview_chart == null or overview_chart.window_size != 32 \
			or not is_equal_approx(overview_chart.min_value, 0.0) \
			or not is_equal_approx(overview_chart.max_value, 1.0):
		failures.append("live patch did not preserve the chart's fixed plotting window")

	panel.select_tab("geography")
	await process_frame
	panel._scroll.scroll_vertical = 96
	var resource_scroll := panel._scroll.scroll_vertical
	var resource_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("geography", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != resource_count:
		failures.append("120 high-speed resource patches changed inspector node count")
	if panel.current_tab() != "geography":
		failures.append("resource live patch changed current tab")
	if panel._scroll.scroll_vertical != resource_scroll:
		failures.append("resource live patch changed scroll position")
	panel.set_model_for_selection(_make_model())
	await process_frame
	if panel.current_tab() != "geography":
		failures.append("selection refresh changed current tab")
	if panel._scroll.scroll_vertical != resource_scroll:
		failures.append("selection refresh changed scroll position")

	panel.select_tab("market")
	await process_frame
	if panel._scroll.scroll_vertical != 0:
		failures.append("tab switch did not reset scroll position")
	var market_list = panel._market_list
	var market_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("market", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != market_count:
		failures.append("120 market patches changed inspector node count")
	var market_refs: Dictionary = market_list._row_refs.get("market_0", {})
	if (market_refs.get("panel") as Node).has_node("Body/Details") \
			or (market_refs.get("panel") as Node).has_node("Body/Button/Header/Chevron"):
		failures.append("market row still contains nested expansion controls")
	if market_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("market list exceeds the inspector scroll width: list=%s scroll=%s" % [
			market_list.get_combined_minimum_size(), panel._scroll.size])

	panel.select_tab("population")
	await process_frame
	var cohort_list = panel._cohort_list
	var cohort_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("population", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != cohort_count:
		failures.append("120 population patches changed inspector node count")
	if cohort_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("population list exceeds the inspector scroll width: list=%s scroll=%s" % [
			cohort_list.get_combined_minimum_size(), panel._scroll.size])
	var cohort_refs: Dictionary = cohort_list._row_refs.get("cohort_1", {})
	if (cohort_refs.get("panel") as Node).has_node("Body/Details") \
			or (cohort_refs.get("panel") as Node).has_node("Body/Button/Header/Chevron"):
		failures.append("population row still contains nested expansion controls")
	if String((cohort_refs.get("name") as Label).text) != "工人" \
			or (cohort_refs.get("icon") as IconBadge).icon_key != "profession.worker" \
			or (cohort_refs.get("living_icon") as IconBadge).icon_key \
					!= "population.living.comfortable" \
			or cohort_refs.has("living_label"):
		failures.append("population header did not separate profession and living-standard icons")
	if cohort_refs.has("income") or cohort_refs.has("expense"):
		failures.append("population header still exposes income or expense")
	if String((cohort_refs.get("wealth") as Label).text).contains("人均") \
			or String((cohort_refs.get("net") as Label).text) != "+4":
		failures.append("population header does not present compact wealth and net values")
	var object_requests := []
	panel.object_details_requested.connect(
		func(request: Dictionary) -> void: object_requests.append(request))
	(cohort_refs.get("button") as Button).pressed.emit()
	if object_requests.size() != 1 \
			or String((object_requests[0] as Dictionary).get("kind", "")) != "cohort":
		failures.append("population row did not request the integrated object detail pane")
	else:
		var cohort_data: Dictionary = (cohort_list._row_data as Dictionary).get(
			"cohort_1", {})
		panel.show_object_detail({
			"kind": "cohort", "name": "工人", "subtitle": "阶层 · 区域 1, 1",
			"icon": "profession.worker", "accent": UITokens.ACCENT,
			"row": cohort_data,
		})
		await process_frame
		if not panel.detail_open() or not panel._detail_shell.visible \
				or panel._object_detail_dialog.title_text() != "工人":
			failures.append("cohort row did not open the embedded detail workspace")
		var detail_text := ""
		for node in panel._object_detail_dialog.find_children(
				"", "Label", true, false):
			detail_text += String((node as Label).text) + "\n"
		if not detail_text.contains("消费需求"):
			failures.append("embedded cohort detail did not include demand data")
		var detail_nav := panel._object_detail_dialog._section_nav as Control
		var operations_button := panel._object_detail_dialog._section_buttons.get(
			"operations") as Button
		if not detail_nav.visible or operations_button == null \
				or not operations_button.visible:
			failures.append("cohort detail section navigation is not interactive")
		else:
			operations_button.pressed.emit()
			await process_frame
			if panel._object_detail_dialog._scroll.scroll_vertical <= 0:
				failures.append("cohort detail operations navigation did not scroll")
		if not (cohort_refs.get("tax_editors", {}) as Dictionary).is_empty():
			failures.append("population row still owns tax editors after tax migration")
		panel.set_compact_detail_mode(true)
		if panel._inspector_root.visible:
			failures.append("compact detail mode did not replace the right overview")
		panel.close_detail()
		if panel.detail_open() or not panel._inspector_root.visible:
			failures.append("closing compact detail did not restore the overview")
		panel.set_compact_detail_mode(false)

	panel.select_tab("buildings")
	await process_frame
	var construction_picker := panel._construction_picker as ConstructionPicker
	if construction_picker == null \
			or construction_picker._status.text != "测试：尚未拥有该地块。":
		failures.append("inspector did not initialize construction picker after adding it to the tree")
	var building_list = panel._building_list
	var building_count := panel.visible_node_count()
	for i in range(40):
		panel.apply_live_patch(_make_patch("buildings", float(i)))
	await process_frame
	if panel.visible_node_count() != building_count:
		failures.append("building live patches changed inspector node count")
	if building_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("building list exceeds the inspector scroll width: list=%s scroll=%s" % [
			building_list.get_combined_minimum_size(), panel._scroll.size])
	var building_refs: Dictionary = building_list._row_refs.get("building_1", {})
	if (building_refs.get("panel") as Node).has_node("Body/Details") \
			or (building_refs.get("panel") as Node).has_node("Body/Button/Header/Chevron"):
		failures.append("building row still contains nested expansion controls")
	if String((building_refs.get("name") as Label).text) != "纺织工坊" \
			or not (building_refs.get("state_icon") as Control).visible:
		failures.append("building header did not keep a name-only title with an abnormal-state icon")

	var deferred_cohorts := (load("res://scenes/ui/cohort_list.tscn") as PackedScene).instantiate() as CohortList
	root.add_child(deferred_cohorts)
	deferred_cohorts.set_rows([])
	deferred_cohorts.update_rows(_population_category(0.0).get("cohort_rows", []))
	if deferred_cohorts._row_refs.size() != 2:
		failures.append("committed cohort rows were not created after an initially partial snapshot")
	var deferred_resources := (load("res://scenes/ui/resource_list.tscn") as PackedScene).instantiate() as ResourceList
	root.add_child(deferred_resources)
	deferred_resources.set_rows([])
	deferred_resources.update_rows(_resource_category(0.0).get("resource_rows", []))
	if deferred_resources._row_refs.size() != 18:
		failures.append("committed market rows were not created after an initially partial snapshot")

	if top_bar.get_combined_minimum_size().x > 1280.0:
		failures.append("top bar minimum width exceeds 1280px")
	if top_bar.get_combined_minimum_size().y > PlayerTopBar.BAR_HEIGHT:
		failures.append("top bar minimum height exceeds configured bar height")
	if panel.get_combined_minimum_size().x > 460.0:
		failures.append("inspector minimum width exceeds 460px: %s" % \
			panel.get_combined_minimum_size())

	var loading := (load("res://scenes/ui/world_loading_overlay.tscn") as PackedScene).instantiate() as WorldLoadingOverlay
	root.add_child(loading)
	await process_frame
	await process_frame
	if not loading.size.is_equal_approx(root.size):
		failures.append("loading overlay does not cover the full viewport")
	var loading_center := loading.get_global_rect().get_center()
	var card_center := loading._card.get_global_rect().get_center()
	if loading_center.distance_to(card_center) > 1.0:
		failures.append("loading card is not centered in the viewport")
	loading.show_message("正在生成世界")
	loading.set_progress("physical", 0.65)
	loading.set_progress("terrain", 0.20)
	if not is_equal_approx(loading._progress.value, 65.0):
		failures.append("loading progress regressed after an older stage update")
	if loading._stage_label.text != "正在烘焙地形与水文图层":
		failures.append("loading stage was not localized for players")
	loading.hide_completed()
	await create_timer(0.55).timeout
	if loading.visible:
		failures.append("loading completion animation did not release the map")

	if failures.is_empty():
		print("[inspector-live-patch] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[inspector-live-patch] FAIL: %s" % failure)
		quit(1)


func _make_model() -> Dictionary:
	return {
		"header": {
			"title": "低地 · 平原",
			"subtitle": "区域 12-8 · 地块档案 #42",
			"badges": _badges(),
		},
		"score": {"id": "habitability", "title": "地块适宜度", "value": 0.72, "caption": "可发展", "accent": UITokens.GOOD},
		"summary_cards": _summary_cards(0.0),
		"tabs": [
			{"id": "geography", "label": "地理信息", "icon": "geo"},
			{"id": "population", "label": "人口信息", "icon": "growth"},
			{"id": "families", "label": "家族", "icon": "family.house"},
			{"id": "market", "label": "市场信息", "icon": "resource"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
		],
		"categories": {
			"geography": _geography_category(0.72),
			"population": _population_category(0.0),
			"families": {},
			"market": _market_category(0.0),
			"buildings": _building_category(0.0),
		},
	}


func _make_patch(tab_id: String, step: float = 1.0) -> Dictionary:
	var category := _geography_category(step)
	match tab_id:
		"market": category = _market_category(step)
		"population": category = _population_category(step)
		"buildings": category = _building_category(step)
	return {
		"header": {
			"title": "低地 · 平原",
			"subtitle": "区域 12-8 · 地块档案 #42",
			"badges": _badges(),
		},
		"score": {"id": "habitability", "title": "地块适宜度", "value": 0.76, "caption": "可发展", "accent": UITokens.GOOD},
		"summary_cards": _summary_cards(step),
		"tab_id": tab_id,
		"category": category,
	}


func _construction_scroll_model() -> Dictionary:
	var items := []
	for i in range(16):
		items.append({
			"building_id": "scroll_test_%d" % i,
			"name": "测试建筑 %02d" % (i + 1),
			"eligible": true,
			"cash_required": 10000,
			"materials": [{
				"name": "木材", "required": 1000,
				"treasury": 1000, "market": 0,
				"unit_price_text": "1.25", "cost_text": "1.25",
			}],
			"inputs": [{"name": "原木", "quantity": "0.500 /日"}],
			"outputs": [{"name": "木板", "quantity": "0.250 /日"}],
			"jobs": [{"name": "工匠", "slots": 4, "owner": false}],
			"icon": "economy.building.workshop",
		})
	return {
		"available": true,
		"items": items,
		"total": items.size(),
		"offset": 0,
		"limit": 32,
	}


func _badges() -> Array:
	return [
		{"text": "平原", "accent": UITokens.GEO},
		{"text": "低地", "accent": UITokens.GEO},
		{"text": "温带草原", "accent": UITokens.ECO},
		{"text": "无覆盖", "accent": UITokens.WATER},
		{"text": "晴朗", "accent": UITokens.WATER},
	]


func _summary_cards(step: float) -> Array:
	return [
		{"id": "summary_climate", "title": "气候", "value": "温暖 · 适中", "subtitle": "", "accent": UITokens.CLIMATE, "icon": "sun"},
		{"id": "summary_population", "title": "人口", "value": "%d 人" % (1200 + int(step)), "subtitle": "4 个阶层", "accent": UITokens.ACCENT, "icon": "growth"},
	]


func _overview_category(value: float) -> Dictionary:
	return {
		"insights": [
			{"id": "overview_passage", "text": "陆路可通 · 移动成本 1", "accent": UITokens.GOOD, "icon": "target"},
			{"id": "overview_resource", "text": "主要资源 · 木材", "accent": UITokens.RESOURCE, "icon": "resource"},
		],
		"metrics": [
			{"id": "overview_surface", "title": "地表", "value": "低地", "subtitle": "平原", "accent": UITokens.GEO, "icon": "surface"},
			{"id": "overview_weather", "title": "天气", "value": "晴朗", "subtitle": "强度轻微", "accent": UITokens.WATER, "icon": "weather"},
		],
		"gauges": [
			{"id": "overview_test_gauge", "label": "环境指数", "value": value, "accent": UITokens.GOOD, "status_label": "稳定", "value_text": "%.2f" % value},
		],
		"charts": [
			{
				"id": "overview_ecology_history",
				"title": "近期生态轨迹",
				"values": [0.4, 0.5, value],
				"accent": UITokens.ECO,
				"min_value": 0.0,
				"max_value": 1.0,
				"window_size": 32,
				"value_text": "现值 %.2f" % value,
			},
		],
	}


func _geography_category(value: float) -> Dictionary:
	var category := _overview_category(value)
	var resource_section := _resource_category(value)
	resource_section["id"] = "natural_resources"
	resource_section["title"] = "自然资源"
	resource_section["icon"] = "eco"
	resource_section["accent"] = UITokens.RESOURCE
	category["sections"] = [resource_section]
	return category


func _resource_category(step: float) -> Dictionary:
	var rows := []
	for i in range(18):
		rows.append({
			"id": "resource_%d" % i,
			"name": "资源样本 %02d" % (i + 1),
			"value": "储量 %s" % UITokens.format_compact_number_cn(12000.0 + i * 100.0 + step, 2),
			"density": "富集",
			"delta": "+1",
			"accent": UITokens.RESOURCE,
			"icon": "resource",
			"visible": i != 17 or step <= 0.0,
		})
	return {
		"insights": [
			{"id": "resource_notable", "text": "木材 · 富集 · +1", "accent": UITokens.RESOURCE, "icon": "resource"},
		],
		"resource_rows": rows,
	}


func _market_category(step: float) -> Dictionary:
	var rows := []
	for i in range(18):
		rows.append({
			"id": "market_%d" % i,
			"name": "商品 %02d" % (i + 1),
			"stock": "%s 单位" % UITokens.format_compact_number_cn(12000.0 + i * 100.0, 2),
			"price": "%.2f" % (1.0 + i * 0.1),
			"delta": "%+.0f" % step,
			"risk": "短缺" if i == 0 else "",
			"accent": UITokens.RESOURCE,
			"icon": "resource",
			"visible": true,
			"detail_rows": [
				{"id": "household", "name": "居民需求", "value": "10"},
				{"id": "business", "name": "产业需求", "value": "5"},
				{"id": "supply", "name": "供给", "value": "12"},
			],
		})
	return {"market_rows": rows}


func _population_category(step: float) -> Dictionary:
	return {
		"cohort_rows": [
			{"id": "cohort_1", "name": "工人", "cohort_identity": "本地人口", "living_standard": "小康", "satisfaction": "82.0%", "worst_dimension": "储蓄", "satisfaction_rows": _satisfaction_rows(step), "population": "1000 人", "wealth": "人均 40", "income": "+12", "expense": "−8", "net": "+4", "status": "本地人口 · 满意度 82.0%", "accent": UITokens.ACCENT, "icon": "profession.worker", "living_icon": "living_comfortable", "living_accent": UITokens.GOOD, "visible": true, "income_rows": [{"id": "income_wages", "name": "工资", "value": "+12/人"}], "expense_rows": [{"id": "expense_goods", "name": "生活消费", "value": "−8/人"}], "demand_rows": _demand_rows(step), "demand_groups": _demand_groups(step), "demand_summary": {"value": "1 项用途 · 2 种商品", "subtitle": "主要：谷物、布料", "total_quantity": "0.840", "total_daily_cost": "1.1"}},
			{"id": "cohort_2", "name": "商人", "cohort_identity": "本地人口", "living_standard": "富裕", "satisfaction": "90.0%", "worst_dimension": "税负", "satisfaction_rows": _satisfaction_rows(step), "population": "10 人", "wealth": "人均 200", "income": "+30", "expense": "−10", "net": "+20", "status": "本地人口 · 满意度 90.0%", "accent": UITokens.RESOURCE, "icon": "profession.merchant", "living_icon": "living_affluent", "living_accent": UITokens.RESOURCE, "visible": true, "income_rows": [{"id": "income_sales", "name": "居民销售", "value": "+30/人"}], "expense_rows": [{"id": "expense_goods", "name": "生活消费", "value": "−10/人"}], "demand_rows": _demand_rows(step), "demand_groups": _demand_groups(step), "demand_summary": {"value": "1 项用途 · 2 种商品", "subtitle": "主要：谷物、布料", "total_quantity": "0.840", "total_daily_cost": "1.1"}},
		],
	}


func _satisfaction_rows(step: float) -> Array:
	return [
		{"id": "satisfaction_dim_0", "name": "温饱",
			"value": "%.1f%%" % (70.0 + step), "accent": UITokens.GOOD,
			"worst": false, "visible": true},
		{"id": "satisfaction_dim_5", "name": "储蓄",
			"value": "%.1f%%" % (12.0 + step), "accent": UITokens.RISK,
			"worst": true, "visible": true},
	]


func _demand_rows(step: float) -> Array:
	return [
		{"id": "demand_grain", "name": "谷物", "quantity": "%.3f" % (0.8 + step * 0.0001), "price": "1.25", "daily_cost": "1", "attribution_available": true, "wealth_delta_raw": 20, "price_delta_raw": -5, "visible": true},
		{"id": "demand_cloth", "name": "布料", "quantity": "0.040", "price": "2.5", "daily_cost": "0.1", "attribution_available": true, "wealth_delta_raw": 0, "price_delta_raw": 0, "visible": true},
	]


func _demand_groups(step: float) -> Array:
	return [{"id": "demand_usage_basic", "name": "基本生活", "satisfaction": "满足 82%", "rows": _demand_rows(step)}]


func _building_category(step: float) -> Dictionary:
	return {
		"construction": {
			"available": false,
			"message": "测试：尚未拥有该地块。",
			"items": [],
			"total": 0,
			"offset": 0,
			"limit": 32,
		},
		"building_rows": [{
			"id": "building_1", "name": "纺织工坊", "count": "2 栋",
			"owner": "业主 · 地主", "status": "亏损停产",
			"profit_label": "状态", "profit": "停产",
			"accent": UITokens.RISK, "icon": "building", "visible": true,
			"state_summary": {"label": "亏损停产", "detail": "建筑仍保留，岗位已释放。",
				"meta": "上一经营期利润率 -50.0% · 连续亏损 3 期",
				"accent": UITokens.RISK, "icon": "warning"},
			"job_rows": [
				{"id": "owner_job", "name": "业主 · 地主", "value": "2 / 2", "ratio": 1.0},
				{"id": "worker_job", "name": "雇员 · 工人", "value": "30 / 40", "ratio": 0.75},
			],
			"production_rows": [
				{"id": "input", "name": "原材料 · 谷物", "value": "1.500 单位/栋/日", "icon": "resource"},
				{"id": "output", "name": "产品 · 玉米", "value": "0.802 单位/栋/日 · 资源充足", "icon": "resource"},
			],
			"finance": {"revenue": "90", "cost": "50", "profit": "+%.1f" % (40.0 + step), "profit_positive": true, "breakdown": "原料 20 · 工资 30", "warning": ""},
		}],
	}
