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
## 真实行构造（construction.gd）的入口，用于 preview 回归护栏。
const CONSTRUCTION_PAGE := preload("res://scripts/ui/cell_inspector/construction.gd")

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
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	# Building rows now hand the full quote to the structured hover card. The
	# native row tooltip is intentionally empty so two overlapping cards cannot
	# appear at once.
	if eligible_row != null and workspace._hover_card != null:
		workspace._on_row_hover_started(eligible_row._row_data, eligible_row)
	await process_frame
	_expect("row hover opens the structured detail card",
		workspace._hover_card.visible
		and String(workspace._hover_card._payload.get("tooltip", "")).contains("国库"))
	_expect("eligible hover hides the empty shortage section",
		not workspace._hover_card._materials.visible)
	var hover := workspace._hover_card
	_expect("hover shows daily inputs, natural resources and outputs",
		workspace._hover_card._flow.visible
		and _visible_rows(workspace._hover_card._outputs) == 1
		and _quantity_row(workspace._hover_card._outputs, 0)
			== PackedStringArray(["木板", "", "0.25/日"])
		and _visible_rows(workspace._hover_card._inputs) == 2
		and _quantity_row(workspace._hover_card._inputs, 0)
			== PackedStringArray(["原木", "", "0.5/日"])
		and _quantity_row(workspace._hover_card._inputs, 1)
			== PackedStringArray(["水源", "自然资源", "0.2/日"])
		and (workspace._hover_card._outputs.get_node("Title") as Label).text == "每栋基础日产")
	_expect("hover shows owner and employee roles",
		workspace._hover_card._employment.visible
		and _visible_rows(workspace._hover_card._employment) == 2
		and _quantity_row(workspace._hover_card._employment, 0)
			== PackedStringArray(["业主", "工匠", "×1"])
		and _quantity_row(workspace._hover_card._employment, 1)
			== PackedStringArray(["雇员", "工人", "×3"]))
	_expect("hover detail stays inside the construction column",
		host.get_global_rect().grow(0.5).encloses(
			workspace._hover_card.get_global_rect()))
	workspace._on_row_hover_ended()
	workspace._on_row_hover_started(blocked_row._row_data, blocked_row)
	await process_frame
	_expect("hover hides sections without recipe or job data",
		not workspace._hover_card._flow.visible and not workspace._hover_card._employment.visible)
	var requirement = hover._requirement_list.get_child(0)
	_expect("blocked hover explains missing amount and market cause",
		hover._requirements.visible
		and String(requirement.get_node("Description/Detail").text).contains("0.6 单位")
		and String(requirement.get_node("Description/Detail").text).contains("市场无货")
		and (requirement.get_node("Icon") as IconBadge).icon_key == &"good.lumber")
	# 数据层仍在：卡片只是不再把每项建材的市场原因排版出来（报告里单列）。
	_expect("blocked material still carries the market cause in the payload",
		String(workspace._hover_card._payload["material_status"][0].get("reason", ""))
			== "市场无货")
	workspace._on_row_hover_ended()
	await _test_real_preview(workspace, eligible_row)
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


## 数量段（Body/Flow/Outputs、Body/Employment…）的可见行数：行是 building_quantity_list.gd
## 预建的，多的只是隐藏，所以要数 visible 不能数 get_child_count。
func _visible_rows(section: Control) -> int:
	return _visible_children(section.get_node("List"))


func _visible_children(container: Node) -> int:
	var count := 0
	for child in container.get_children():
		if (child as Control).visible:
			count += 1
	return count


## 一行数量行的三个字段：名称 / 明细 / 数量（building_quantity_list.gd:19-28）。
func _quantity_row(section: Control, index: int) -> PackedStringArray:
	var line := section.get_node("List").get_child(index)
	return PackedStringArray([
		(line.get_node("Description/Name") as Label).text,
		(line.get_node("Description/Detail") as Label).text,
		(line.get_node("Quantity") as Label).text,
	])


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _row(building_id: String, display_name: String, eligible: bool, cash: int,
		reason: String) -> Dictionary:
	var production := "\n岗位：业主 工匠 ×1 · 雇员 工人 ×3\n投入：原木 0.5/日\n自然资源：水源 0.2/日\n产出：木板 0.25/日" \
		if building_id == "weaving" else ""
	# 704de6648 起卡片改按 preview 的 List 渲染（building_hover_card.gd:139-145），
	# 原来那张多行 _flow_text 不存在了。preview 与行内 tooltip 必须描述同一组数字。
	var preview := {} if building_id != "weaving" else {
		"outputs_title": "每栋基础日产",
		"outputs": [{"name": "木板", "icon": &"metric.goods", "text": "0.25/日"}],
		"inputs": [
			{"name": "原木", "icon": &"metric.goods", "text": "0.5/日"},
			{"name": "水源", "icon": &"metric.goods", "text": "0.2/日", "detail": "自然资源"},
		],
		"jobs": [
			{"name": "业主", "icon": &"population.crowd", "text": "×1", "detail": "工匠"},
			{"name": "雇员", "icon": &"population.crowd", "text": "×3", "detail": "工人"},
		],
	}
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
		"preview": preview,
		"material_status": [{
			"name": "木材", "missing": not eligible,
			"icon": "good.lumber",
			"text": "2.4 单位", "detail": "国库 1.8，需市购 0.6",
			"missing_text": "0.6", "reason": "市场无货",
		}],
		"cash_blocked": reason == "资金不足",
		"tooltip": "%s\n木材 · 需 2.4 / 国库 1.8 / 市购 0.6\n合计需现金 %.1f%s" % [
			display_name, float(cash) / 10000.0, production],
	}


func _quantity_row_matches(section: Control, index: int, name_text: String, quantity: String) -> bool:
	var rows := section.get_node("List")
	if index >= rows.get_child_count():
		return false
	var row := rows.get_child(index) as Control
	return row.visible and row.get_node("Description/Name").text == name_text \
		and row.get_node("Quantity").text == quantity


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


## 回归护栏：用真实 construction.gd 造一行真实 payload，断言 preview 三键非空，
## 再把这份真实 payload 喂给真实卡片，逐行核对它渲染出来的投入/自然资源/产出与岗位。
##
## 为什么要这条：上面那几条 hover 断言能绿，是因为 fixture 自己塞了 preview。
## 704de6648 把卡片改成只认 payload.preview，而行构造端当时没有这个键，
## 于是「卡片结构对了、数据没接上」这种漏接在测试里完全看不见。
func _test_real_preview(workspace: BuildingWorkspace, source: Control) -> void:
	GoodProfileRegistry.ensure_loaded()
	ResourceProfileRegistry.ensure_loaded()
	var entries := [{
		"index": 0, "type_id": 0, "building_id": "weaving", "name": "织造工坊",
		"icon": &"economy.building.workshop", "eligible": true, "reason_code": "ok",
		"cash_required": 32000, "days": 3,
	}]
	var quotes := {"items": [{"materials": []}]}
	var rows: Array = CONSTRUCTION_PAGE.new()._construction_page_rows(
		HostStub.new(), entries, quotes, {}, EconomyStub.new(), {}, PackedStringArray(["成熟"]))
	_expect("real construction row is produced", rows.size() == 1)
	if rows.is_empty():
		return
	var payload: Dictionary = rows[0]
	var preview: Dictionary = payload.get("preview", {})
	var outputs: Array = preview.get("outputs", [])
	var inputs: Array = preview.get("inputs", [])
	var jobs: Array = preview.get("jobs", [])
	print("[preview] outputs=%d inputs=%d jobs=%d -> %s" % [
		outputs.size(), inputs.size(), jobs.size(), preview])
	_expect("real construction payload carries preview.outputs/inputs/jobs",
		not outputs.is_empty() and not inputs.is_empty() and not jobs.is_empty())
	_expect("preview row counts", outputs.size() == 1 and inputs.size() == 2
		and jobs.size() == 2)

	workspace._on_row_hover_started(payload, source)
	await process_frame
	var card = workspace._hover_card
	_expect("real payload renders the output row",
		card._flow.visible and _visible_rows(card._outputs) == 1
		and _quantity_row(card._outputs, 0) == PackedStringArray(["日晒土坯", "", "0.25/日"]))
	_expect("real payload renders input and natural-resource rows",
		_visible_rows(card._inputs) == 2
		and _quantity_row(card._inputs, 0) == PackedStringArray(["原木", "", "0.5/日"])
		and _quantity_row(card._inputs, 1) == PackedStringArray(["黏土", "自然资源", "0.2/日"]))
	_expect("real payload renders owner and employee rows",
		card._employment.visible and _visible_rows(card._employment) == 2
		and _quantity_row(card._employment, 0) == PackedStringArray(["工匠", "业主", "×1"])
		and _quantity_row(card._employment, 1) == PackedStringArray(["建筑工人", "雇员", "×3"]))
	workspace._on_row_hover_ended()
	await process_frame


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


# ─────────────────── 真实行构造用的取值桩 ───────────────────
#
# 生产里 host 是 CellInspector。这些桩只按生产签名摆出 host 侧的取值函数，
# 行构造本身（construction.gd:_construction_page_rows）与 Recipes / 两个 registry
# 全部走真实代码——护栏要抓的正是「行构造没把 preview 交出去」这种漏接。

class FacadeStub extends RefCounted:
	func profession_display_name(profession_id: StringName) -> String:
		var names := {"artisan": "工匠", "construction_worker": "建筑工人"}
		return String(names.get(String(profession_id), String(profession_id)))


class GeneratorStub extends RefCounted:
	func get_economy_facade() -> Object:
		return FacadeStub.new()


class HostStub extends RefCounted:
	const Recipes := preload("res://scripts/ui/cell_inspector/construction_recipes.gd")
	const MONEY_SCALE := 10000

	var _generator = null

	func _init() -> void:
		_generator = GeneratorStub.new()

	func _construction_local_stock(_market: Dictionary) -> Dictionary:
		return {}

	func _construction_materials_text(_materials: Array) -> String:
		return ""

	func _construction_material_status_rows(_materials: Array, _stock: Dictionary) -> Array:
		return []

	func _construction_reason_text(_code: String, _materials: Array,
			_stock: Dictionary) -> String:
		return ""

	func _unlocked_good_ids(_snapshot: Dictionary) -> Dictionary:
		return {}

	func _construction_tooltip(_entry: Dictionary, _item: Dictionary, _materials: Array,
			_stock: Dictionary, _placement: Dictionary, _job_spec: Dictionary,
			_unlocked: Dictionary, _days: int, _maturity: String, _reason: String) -> String:
		return ""

	func _construction_recipe_rows(placement: Dictionary, ids_key: String,
			quantities_key: String, label: String) -> Array:
		return Recipes._construction_recipe_rows(self, placement, ids_key, quantities_key, label)

	func _construction_input_recipe_rows(placement: Dictionary, unlocked: Dictionary) -> Array:
		return Recipes._construction_input_recipe_rows(self, placement, unlocked)

	func _construction_input_candidate_label(placement: Dictionary, input_idx: int,
			unlocked: Dictionary) -> String:
		return Recipes._construction_input_candidate_label(self, placement, input_idx, unlocked)

	func _format_input_candidate_label(good_id: String, efficiency_q16: int) -> String:
		var label := _good_display_name(good_id)
		if efficiency_q16 != 65536:
			label += " %.0f%%" % (float(efficiency_q16) * 100.0 / 65536.0)
		return label

	func _good_display_name(stable_id: String) -> String:
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		return String(profile.display_name) \
			if profile != null and String(profile.display_name) != "" else stable_id

	func _resource_display_name(stable_id: String) -> String:
		for profile in ResourceProfileRegistry.ordered():
			if String(profile.id) == stable_id:
				return String(profile.display_name) \
					if String(profile.display_name) != "" else stable_id
		return stable_id

	func _goods_scaled(value: int) -> String:
		return Recipes._goods_scaled(self, value)

	func _money_text(subunits: int) -> String:
		if subunits != 0 and absi(subunits) < 100:
			return "%.4f" % (float(subunits) / MONEY_SCALE)
		return UITokens.format_compact_number_cn(float(subunits) / MONEY_SCALE, 2)

	func _construction_profession_name(profession_id: String) -> String:
		return Recipes._construction_profession_name(self, profession_id)


class EconomyStub extends RefCounted:
	func building_placement_spec(_building_id: StringName) -> Dictionary:
		return {
			"output_good_ids": PackedStringArray(["adobe_brick"]),
			"output_quantities": PackedInt64Array([250]),
			"input_good_ids": PackedStringArray(["logs"]),
			"input_quantities": PackedInt64Array([500]),
			"resource_ids": PackedStringArray(["clay"]),
			"resource_quantities": PackedInt64Array([200]),
			"resource_modes": PackedInt32Array([0]),
		}

	func building_job_spec(_building_id: StringName) -> Dictionary:
		return {"ok": true, "owner_slots": 1, "owner_profession": "artisan",
			"employee_professions": PackedStringArray(["construction_worker"]),
			"employee_slots": PackedInt64Array([3])}
