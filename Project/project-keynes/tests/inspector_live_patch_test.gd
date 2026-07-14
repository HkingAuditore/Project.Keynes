extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	var root := Control.new()
	root.size = Vector2(1280.0, 720.0)
	root.theme = UITokens.make_player_theme()
	get_root().add_child(root)

	var top_bar := PlayerTopBar.new()
	top_bar.position = Vector2.ZERO
	top_bar.size = Vector2(1280.0, PlayerTopBar.BAR_HEIGHT)
	root.add_child(top_bar)
	top_bar.set_world_summary(60, 40, 2400, 123456)
	top_bar.update_time_state(9, 6, 18, false, 20.0)
	if top_bar._date_label.text != "第10年 · 6月18日":
		failures.append("top bar did not display the current year and calendar date")

	var panel := InspectorPanel.new()
	panel.position = Vector2(820.0, 60.0)
	panel.size = Vector2(460.0, 648.0)
	root.add_child(panel)
	await process_frame

	var model := _make_model()
	panel.set_model_for_selection(model)
	await process_frame
	for button in panel._tabs._buttons.values():
		if not String((button as Button).text).is_empty():
			failures.append("dossier tab header still displays text")
		var icons := (button as Button).find_children("", "IconBadge", true, false)
		if icons.size() != 1 or (icons[0] as Control).get_global_rect().get_center().distance_to(
			(button as Control).get_global_rect().get_center()) > 1.0:
			failures.append("dossier tab icon is not geometrically centered")
	for raw_card in panel._summary_cards.values():
		var summary_card := raw_card as MetricCard
		if summary_card != null and summary_card.size.x < 220.0:
			failures.append("summary cards did not expand into full-width dossier rows")
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

	panel.select_tab("natural_resources")
	await process_frame
	panel._scroll.scroll_vertical = 96
	var resource_scroll := panel._scroll.scroll_vertical
	var resource_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("natural_resources", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != resource_count:
		failures.append("120 high-speed resource patches changed inspector node count")
	if panel.current_tab() != "natural_resources":
		failures.append("resource live patch changed current tab")
	if panel._scroll.scroll_vertical != resource_scroll:
		failures.append("resource live patch changed scroll position")

	panel.select_tab("market")
	await process_frame
	var market_list = panel._market_list
	market_list.set_expanded("market_0", true)
	var market_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("market", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != market_count:
		failures.append("120 market patches changed inspector node count")
	if not market_list.is_expanded("market_0"):
		failures.append("market live patch lost row expansion state")
	if market_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("expanded market list exceeds the inspector scroll width")

	panel.select_tab("population")
	await process_frame
	var cohort_list = panel._cohort_list
	cohort_list.set_expanded("cohort_1", true)
	var cohort_count := panel.visible_node_count()
	for i in range(120):
		panel.apply_live_patch(_make_patch("population", float(i)))
		if i % 20 == 0:
			await process_frame
	if panel.visible_node_count() != cohort_count:
		failures.append("120 population patches changed inspector node count")
	if not cohort_list.is_expanded("cohort_1"):
		failures.append("population live patch lost cohort expansion state")
	if cohort_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("expanded population list exceeds the inspector scroll width")
	var cohort_refs: Dictionary = cohort_list._row_refs.get("cohort_1", {})
	if not String((cohort_refs.get("income") as Label).text).begins_with("收入 ") \
			or not String((cohort_refs.get("expense") as Label).text).begins_with("支出 "):
		failures.append("population header does not identify income and expense as ledger entries")
	var demand_requests := []
	panel.demand_details_requested.connect(
		func(details: Dictionary) -> void: demand_requests.append(details))
	var demand_refs: Dictionary = cohort_refs.get("demand", {})
	(demand_refs.get("button") as Button).pressed.emit()
	if demand_requests.size() != 1 \
			or String((demand_requests[0] as Dictionary).get("cohort_name", "")) != "工人 · 本地人口" \
			or ((demand_requests[0] as Dictionary).get("rows", []) as Array).size() != 2:
		failures.append("population demand detail action did not forward the selected cohort payload")
	else:
		var dialog = load("res://scripts/ui/components/demand_detail_dialog.gd").new()
		root.add_child(dialog)
		dialog.show_details(demand_requests[0])
		await process_frame
		var visible_detail_labels := 0
		for child in dialog._rows_grid.get_children():
			if child is Label and (child as Label).visible:
				visible_detail_labels += 1
		var dialog_panels: Array[Node] = dialog.find_children(
			"", "PanelContainer", true, false)
		if not dialog.is_open() or visible_detail_labels != 8:
			failures.append("demand detail dialog did not render two four-column rows")
		elif dialog_panels.is_empty() \
				or (dialog_panels[0] as Control).size.x > 1280.0 \
				or (dialog_panels[0] as Control).size.y > 720.0:
			failures.append("demand detail dialog exceeds the 1280x720 viewport")
		dialog.close_dialog()
		if dialog.visible:
			failures.append("demand detail dialog did not close")

	panel.select_tab("buildings")
	await process_frame
	var building_list = panel._building_list
	building_list.set_expanded("building_1", true)
	var building_count := panel.visible_node_count()
	for i in range(40):
		panel.apply_live_patch(_make_patch("buildings", float(i)))
	await process_frame
	if panel.visible_node_count() != building_count:
		failures.append("building live patches changed inspector node count")
	if not building_list.is_expanded("building_1"):
		failures.append("building live patch lost expansion state")
	if building_list.get_combined_minimum_size().x > panel._scroll.size.x + 0.5:
		failures.append("expanded building list exceeds the inspector scroll width")
	var building_refs: Dictionary = building_list._row_refs.get("building_1", {})
	for group_id in ["jobs", "production", "finance"]:
		var group_panel := ((building_refs.get(group_id, {}) as Dictionary).get("panel") as Control)
		if group_panel != null and group_panel.size.x > building_list.size.x + 0.5:
			failures.append("expanded building %s card exceeds the building list width" % group_id)
			break

	var deferred_cohorts := CohortList.new()
	root.add_child(deferred_cohorts)
	deferred_cohorts.set_rows([])
	deferred_cohorts.update_rows(_population_category(0.0).get("cohort_rows", []))
	if deferred_cohorts._row_refs.size() != 2:
		failures.append("committed cohort rows were not created after an initially partial snapshot")
	var deferred_resources := ResourceList.new()
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
		failures.append("inspector minimum width exceeds 460px")

	var loading := WorldLoadingOverlay.new()
	loading.size = Vector2(1280.0, 720.0)
	root.add_child(loading)
	loading.show_message("正在生成世界")
	loading.set_progress("正在校准水文资料", 0.65)
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
			{"id": "market", "label": "市场信息", "icon": "resource"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
			{"id": "natural_resources", "label": "自然资源", "icon": "eco"},
		],
		"categories": {
			"geography": _overview_category(0.72),
			"population": _population_category(0.0),
			"market": _market_category(0.0),
			"buildings": _building_category(0.0),
			"natural_resources": _resource_category(0.0),
		},
	}


func _make_patch(tab_id: String, step: float = 1.0) -> Dictionary:
	var category := _overview_category(0.76)
	match tab_id:
		"market": category = _market_category(step)
		"natural_resources": category = _resource_category(step)
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
			{"id": "cohort_1", "name": "工人 · 本地人口", "population": "1000 人", "wealth": "人均 40", "income": "+12", "expense": "−8", "net": "+4", "status": "需求满足 80% · 结算 5日", "accent": UITokens.ACCENT, "icon": "growth", "visible": true, "income_rows": [{"id": "income_wages", "name": "工资", "value": "+12/人"}], "expense_rows": [{"id": "expense_goods", "name": "生活消费", "value": "−8/人"}], "demand_rows": _demand_rows(step), "demand_summary": {"value": "2 类 · %.3f 单位/人/日" % (0.84 + step * 0.0001), "subtitle": "主要：谷物、布料", "total_quantity": "0.840", "total_daily_cost": "1.1"}},
			{"id": "cohort_2", "name": "商人 · 本地人口", "population": "10 人", "wealth": "人均 200", "income": "+30", "expense": "−10", "net": "+20", "status": "商人 · 需求满足 90% · 结算 5日", "accent": UITokens.RESOURCE, "icon": "growth", "visible": true, "income_rows": [{"id": "income_sales", "name": "居民销售", "value": "+30/人"}], "expense_rows": [{"id": "expense_goods", "name": "生活消费", "value": "−10/人"}], "demand_rows": _demand_rows(step), "demand_summary": {"value": "2 类 · 0.840 单位/人/日", "subtitle": "主要：谷物、布料", "total_quantity": "0.840", "total_daily_cost": "1.1"}},
		],
	}


func _demand_rows(step: float) -> Array:
	return [
		{"id": "demand_grain", "name": "谷物", "quantity": "%.3f" % (0.8 + step * 0.0001), "price": "1.25", "daily_cost": "1", "visible": true},
		{"id": "demand_cloth", "name": "布料", "quantity": "0.040", "price": "2.5", "daily_cost": "0.1", "visible": true},
	]


func _building_category(step: float) -> Dictionary:
	return {
		"building_rows": [{
			"id": "building_1", "name": "纺织工坊", "count": "2 栋",
			"owner": "业主 · 地主", "status": "产能 75.0%",
			"profit_label": "利润", "profit": "+%.1f" % (40.0 + step),
			"accent": UITokens.GOOD, "icon": "building", "visible": true,
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
