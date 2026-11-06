extends SceneTree

## 营造窗口（BuildingWorkspace）的契约测试：不需要渲染，也不需要原生扩展。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/ui/building_workspace_test.gd
##
## 覆盖：行数 / 按钮可用性即「能不能建」 / 行内因由 / 金币图标 /
## 同身份刷新只写值不重建 / 换身份重建 / 空态纸笺 / 424px 页宽不横向溢出。

const WORKSPACE_SCENE := "res://scenes/ui/building_workspace.tscn"
const SESSION_THEME := "res://assets/themes/player_session_theme.tres"
const PAGE_WIDTH := 424.0
const PAGE_HEIGHT := 720.0

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root := Control.new()
	root.size = Vector2(1280.0, 720.0)
	root.theme = load(SESSION_THEME) as Theme
	get_root().add_child(root)

	var host := Control.new()
	host.custom_minimum_size = Vector2(PAGE_WIDTH, PAGE_HEIGHT)
	host.size = Vector2(PAGE_WIDTH, PAGE_HEIGHT)
	root.add_child(host)

	var workspace := (load(WORKSPACE_SCENE) as PackedScene).instantiate() as BuildingWorkspace
	_expect("workspace scene instantiates", workspace != null)
	if workspace == null:
		_finish()
		return
	host.add_child(workspace)
	await process_frame
	await process_frame

	# 模型可以先于入树送达：set_model 在 _ready 之前只存不画。
	var deferred := (load(WORKSPACE_SCENE) as PackedScene).instantiate() as BuildingWorkspace
	deferred.set_model(_model([_row("weaving", "织造工坊", true, 32000, ""),
		_row("masonry", "石作工坊", true, 0, ""), _row("forge", "锻造工坊", false, 12000, "缺建材")]))
	root.add_child(deferred)
	await process_frame
	_expect("model delivered before entering the tree still renders",
		deferred._rows.get_child_count() == 3)
	deferred.queue_free()
	await process_frame

	workspace.set_model(_model([_row("weaving", "织造工坊", true, 32000, ""),
		_row("masonry", "石作工坊", true, 0, ""), _row("forge", "锻造工坊", false, 12000, "缺建材")]))
	await process_frame
	await process_frame

	_expect("three rows render", workspace._rows.get_child_count() == 3)
	var eligible_row := workspace._rows.get_child(0) as BuildingOptionRow
	var free_row := workspace._rows.get_child(1) as BuildingOptionRow
	var blocked_row := workspace._rows.get_child(2) as BuildingOptionRow
	_expect("eligible row enables its build button",
		eligible_row != null and not eligible_row._build.disabled)
	_expect("blocked row disables its build button",
		blocked_row != null and blocked_row._build.disabled)
	_expect("blocked row states the reason inline",
		blocked_row != null and blocked_row._meta.text.begins_with("缺建材"))
	_expect("blocked row tints its cost line", blocked_row != null
		and blocked_row._meta.get_theme_color("font_color") == UITokens.DOSSIER_OXBLOOD)
	_expect("row with cash shows the money icon slot",
		eligible_row != null and eligible_row._cash_row.visible
		and eligible_row._cash_icon.texture == MoneyDisplay.ICON)
	_expect("row without cash hides the money slot",
		free_row != null and not free_row._cash_row.visible)
	_expect("row tooltip carries the hover detail",
		eligible_row != null and eligible_row.tooltip_text.contains("国库"))
	_expect("page has no KPI band: sorting chips and rows carry the decisions",
		workspace.get_node_or_null("%Summary") == null
		and workspace.get_node_or_null("%KpiRow") == null)
	_expect("sector nav mirrors the five departments",
		workspace._sector_nav.chapters.size() == 5)
	_expect("sector chapters keep catalog order and ids",
		_chapter_ids(workspace)
			== PackedStringArray(["agriculture", "extractive", "manufacturing",
				"energy", "knowledge"]))
	_expect("page fits the 424 px detail column",
		workspace.get_combined_minimum_size().x <= PAGE_WIDTH + 1.0)
	_expect("search row stays hidden for a single page", not workspace._filter_row.visible)
	_expect("sort row shows the three orderings",
		(workspace._sort_buttons["recommended"] as Button).text == "推荐"
		and (workspace._sort_buttons["cost"] as Button).text == "造价"
		and (workspace._sort_buttons["newest"] as Button).text == "最新")
	_expect("the model's ordering is the pressed chip",
		(workspace._sort_buttons["recommended"] as Button).button_pressed
		and not (workspace._sort_buttons["newest"] as Button).button_pressed)
	var sort_requests: Array = []
	var sort_handler := func(sector: String, search: String, sort: String,
			offset: int) -> void:
		sort_requests.append([sector, search, sort, offset])
	workspace.page_requested.connect(sort_handler)
	(workspace._sort_buttons["newest"] as Button).pressed.emit()
	_expect("picking an ordering re-queries from the first page",
		sort_requests.size() == 1 and String(sort_requests[0][2]) == "newest"
		and int(sort_requests[0][3]) == 0 and String(sort_requests[0][0]) == "manufacturing")
	(workspace._sort_buttons["recommended"] as Button).pressed.emit()
	_expect("re-pressing the active ordering does not re-query",
		sort_requests.size() == 1)
	workspace.page_requested.disconnect(sort_handler)

	# 同身份刷新：只写值，节点数不变。
	var nodes_before := _count_nodes(workspace)
	var refreshed := _model([_row("weaving", "织造工坊", true, 64000, ""),
		_row("masonry", "石作工坊", true, 0, ""), _row("forge", "锻造工坊", false, 0, "资金不足")])
	workspace.set_model(refreshed)
	await process_frame
	await process_frame
	var refreshed_row := workspace._rows.get_child(0) as BuildingOptionRow
	_expect("same-identity refresh keeps the node count",
		_count_nodes(workspace) == nodes_before)
	_expect("same-identity refresh rewrites values only",
		refreshed_row != null and refreshed_row._cash.text == "6.4"
		and refreshed_row.building_id == "weaving")
	_expect("same-identity refresh keeps the same row instances",
		refreshed_row != null and refreshed_row == eligible_row)

	# 换身份（翻页）：重建行节点。
	var second_page := _model([_row("loom", "提花作坊", true, 8000, "")])
	second_page["offset"] = 16
	second_page["total"] = 17
	second_page["page_label"] = "17–17 / 17"
	workspace.set_model(second_page)
	await process_frame
	await process_frame
	_expect("identity change rebuilds the rows",
		workspace._rows.get_child_count() == 1
		and (workspace._rows.get_child(0) as BuildingOptionRow).building_id == "loom")
	_expect("pager appears when the department spans pages",
		workspace._footer.visible and not workspace._prev_button.disabled
		and workspace._next_button.disabled)

	# 排序档变化 = 新身份：即使条目相同也要重建（否则行序会停在上一次）。
	var before_sort_row := workspace._rows.get_child(0) as BuildingOptionRow
	var sorted_model := _model([_row("weaving", "织造工坊", true, 32000, ""),
		_row("masonry", "石作工坊", true, 0, "")])
	sorted_model["sort"] = "newest"
	sorted_model["sorts"] = _sorts("newest")
	sorted_model["query"]["sort"] = "newest"
	workspace.set_model(sorted_model)
	await process_frame
	await process_frame
	_expect("changing the ordering rebuilds the page",
		workspace._rows.get_child_count() == 2
		and (workspace._rows.get_child(0) as BuildingOptionRow) != before_sort_row)
	_expect("changing the ordering presses the new chip",
		(workspace._sort_buttons["newest"] as Button).button_pressed)

	# 空目录 / 非本国领土：只留纸笺。
	var blocked := _model([])
	blocked["available"] = false
	blocked["message"] = "只能在本国领土内营造。"
	workspace.set_model(blocked)
	await process_frame
	await process_frame
	_expect("blocked model shows the paper note",
		workspace._empty_note.visible
		and workspace._empty_label.text == "只能在本国领土内营造。")
	_expect("blocked model renders no rows", workspace._rows.get_child_count() == 0)
	_expect("blocked model fits the detail column",
		workspace.get_combined_minimum_size().x <= PAGE_WIDTH + 1.0)

	# 反馈纸笺：成功绿、失败朱红，失败会清掉 pending。
	workspace.set_feedback("已排入明日建设队列。", true)
	_expect("feedback note shows the command result",
		workspace._status_note.visible and not workspace._status_label.text.is_empty())
	workspace.set_feedback("国库现金不足。", false)
	_expect("failed feedback turns the note to oxblood",
		workspace._status_label.get_theme_color("font_color") == UITokens.DOSSIER_OXBLOOD)

	_finish()


func _finish() -> void:
	print("=== building workspace: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _chapter_ids(workspace: BuildingWorkspace) -> PackedStringArray:
	var ids := PackedStringArray()
	for chapter in workspace._sector_nav.chapters:
		ids.append(String((chapter as Dictionary).get("id", "")))
	return ids


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _row(building_id: String, display_name: String, eligible: bool, cash: int,
		reason: String) -> Dictionary:
	return {
		"building_id": building_id,
		"type_id": 1,
		"name": display_name,
		"icon": "economy.building.workshop",
		"eligible": eligible,
		"blocked": not eligible,
		"reason_code": "ok" if eligible else "construction_materials_insufficient",
		"reason_text": "" if eligible else reason,
		"materials_text": "木材 2.4 · 石料 1.2",
		"cash_required": cash,
		"cash_text": "%.1f" % (float(cash) / 10000.0),
		"market_used": 600,
		"tooltip": "%s\n木材 · 需 2.4 / 国库 1.8 / 市购 0.6\n合计需现金 %.1f" % [
			display_name, float(cash) / 10000.0],
	}


func _model(rows: Array) -> Dictionary:
	var sectors := []
	var names := ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
	var labels := ["农业", "采掘", "制造", "能源", "知识"]
	for index in range(names.size()):
		sectors.append({
			"id": names[index], "label": labels[index],
			"icon": "economy.building.factory", "count": 3 if index == 2 else 1,
			"question": "%s · 可营造" % labels[index],
			"selected": index == 2,
		})
	return {
		"available": true, "message": "", "data_pending": false,
		"cell": 12, "sector": "manufacturing", "search": "", "sort": "recommended",
		"offset": 0, "limit": 16,
		"total": rows.size(), "sector_total": rows.size(),
		"header": {"kicker": "营造目录", "title": "新建建筑",
			"subtitle": "低地 · 平原 · 国库出资，缺料市购"},
		"sectors": sectors,
		"sorts": _sorts("recommended"),
		"items": rows,
		"page_label": "1–%d / %d" % [rows.size(), rows.size()],
		"query": {"sector": "manufacturing", "search": "", "sort": "recommended",
			"offset": 0},
	}


func _sorts(selected: String) -> Array:
	return [
		{"id": "recommended", "label": "推荐", "selected": selected == "recommended",
			"tooltip": "可建优先，再按估算毛利/日从高到低"},
		{"id": "cost", "label": "造价", "selected": selected == "cost",
			"tooltip": "可建优先，再按现金支出从低到高"},
		{"id": "newest", "label": "最新", "selected": selected == "newest",
			"tooltip": "可建优先，再按生产成熟度从新到旧"},
	]


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
