extends VBoxContainer
class_name CohortList

const CohortRowScene := preload("res://scenes/ui/cohort_row.tscn")
const LedgerRowScene := preload("res://scenes/ui/ledger_row.tscn")

signal demand_details_requested(details: Dictionary)
signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _expanded: Dictionary = {}
var _row_data: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_expanded.clear()
	_row_data.clear()
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "cohort_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id, data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for refs in _row_refs.values():
		var panel := (refs as Dictionary).get("panel") as PanelContainer
		if panel != null:
			panel.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id, data)
		_row_data[row_id] = data.duplicate(true)
		_apply_row(row_id, _row_refs[row_id], data)


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id):
		return
	_expanded[row_id] = expanded
	var refs: Dictionary = _row_refs[row_id]
	var chevron := refs.get("chevron") as Button
	if chevron != null:
		IconButton.apply(chevron,
			&"action.chevron_down" if expanded else &"action.chevron_right",
			IconButton.SMALL, "展开 / 折叠", true, expanded)
	(refs.get("details") as Control).visible = expanded


func is_expanded(row_id: String) -> bool:
	return bool(_expanded.get(row_id, false))


func _create_row(row_id: String, data: Dictionary) -> Dictionary:
	var panel := CohortRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "cohort", "row_id": row_id,
			"profession_id": String((_row_data.get(row_id, {}) as Dictionary) \
				.get("profession_id", ""))}))
	var chevron := panel.get_node("Body/Button/Header/Chevron") as Button
	chevron.toggled.connect(func(expanded: bool) -> void: set_expanded(row_id, expanded))
	var living_icon := panel.get_node("Body/Button/Header/LivingIcon") as IconBadge
	living_icon.mouse_filter = Control.MOUSE_FILTER_STOP
	var income_group := {"panel": panel.get_node("Body/Details/IncomeGroup"),
		"rows": panel.get_node("Body/Details/IncomeGroup/Box/Rows"), "refs": {}, "accent": UITokens.GOOD}
	var expense_group := {"panel": panel.get_node("Body/Details/ExpenseGroup"),
		"rows": panel.get_node("Body/Details/ExpenseGroup/Box/Rows"), "refs": {}, "accent": UITokens.RISK}
	(panel.get_node("Body/Details/IncomeGroup/Box/TitleRow/Icon") as IconBadge).set_semantic(&"trend_up", UITokens.GOOD)
	(panel.get_node("Body/Details/ExpenseGroup/Box/TitleRow/Icon") as IconBadge).set_semantic(&"trend_down", UITokens.RISK)
	var demand_button := panel.get_node("Body/Details/Demand/Box/Top/DetailsButton") as Button
	IconButton.apply(demand_button, &"summary.overview", 13, "查看消费需求明细")
	demand_button.pressed.connect(func() -> void: _request_demand_details(row_id))
	var finance := {"income": panel.get_node("Body/Details/Finance/Grid/Income/Value"),
		"expense": panel.get_node("Body/Details/Finance/Grid/Expense/Value"),
		"net": panel.get_node("Body/Details/Finance/Grid/Net/Value")}
	var demand := {"panel": panel.get_node("Body/Details/Demand"),
		"value": panel.get_node("Body/Details/Demand/Box/Top/Value"),
		"subtitle": panel.get_node("Body/Details/Demand/Box/Subtitle"), "button": demand_button}
	var refs := {"panel": panel, "button": button, "chevron": chevron,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"living_icon": living_icon, "name": panel.get_node("Body/Button/Header/Identity/Name"),
		"population": panel.get_node("Body/Button/Header/Population"),
		"wealth": panel.get_node("Body/Button/Header/Balance/Wealth"),
		"net": panel.get_node("Body/Button/Header/Balance/Net"),
		"details": panel.get_node("Body/Details"),
		"finance": finance, "income_group": income_group,
		"expense_group": expense_group, "demand": demand}
	_apply_row(row_id, refs, data)
	return refs


func _request_demand_details(row_id: String) -> void:
	var data: Dictionary = _row_data.get(row_id, {})
	if data.is_empty():
		return
	var summary: Dictionary = data.get("demand_summary", {})
	demand_details_requested.emit({
		"cohort_name": "%s · %s · %s · 满意度 %s" % [
			String(data.get("name", "阶层")),
			String(data.get("cohort_identity", "本地人口")),
			String(data.get("living_standard", "待评估")),
			String(data.get("satisfaction", "—"))],
		"rows": (data.get("demand_rows", []) as Array).duplicate(true),
		"groups": (data.get("demand_groups", []) as Array).duplicate(true),
		"total_quantity": String(summary.get("total_quantity", "—")),
		"total_daily_cost": String(summary.get("total_daily_cost", "—")),
	})


func _sync_ledger_rows(group: Dictionary, rows: Array) -> void:
	var container := group.get("rows") as VBoxContainer
	var refs: Dictionary = group.get("refs", {})
	for ref in refs.values():
		((ref as Dictionary).get("root") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "row_%d" % refs.size()))
		if not refs.has(row_id):
			var line := LedgerRowScene.instantiate() as HBoxContainer
			container.add_child(line)
			var name_label := line.get_node("Name") as Label
			var value_label := line.get_node("Value") as Label
			value_label.add_theme_color_override("font_color", group.get("accent", UITokens.TEXT_MAIN))
			refs[row_id] = {"root": line, "name": name_label, "value": value_label}
		var ref: Dictionary = refs[row_id]
		(ref.get("root") as Control).visible = bool(data.get("visible", true))
		(ref.get("name") as Label).text = String(data.get("name", ""))
		(ref.get("value") as Label).text = String(data.get("value", ""))
	group["refs"] = refs
	(group.get("panel") as Control).visible = not rows.is_empty()


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	(refs.get("icon") as IconBadge).set_semantic(
		StringName(data.get("icon", &"ecology.growth")), accent)
	var living_accent: Color = data.get("living_accent", UITokens.TEXT_MUTED)
	var living_badge := refs.get("living_icon") as IconBadge
	living_badge.set_semantic(
		StringName(data.get("living_icon", &"action.history")), living_accent)
	var living_text := String(data.get("living_standard", "待评估"))
	living_badge.tooltip_text = "%s · 满意度 %s" % [
		living_text,
		String(data.get("satisfaction", "—"))]
	var name_label := refs.get("name") as Label
	name_label.text = String(data.get("name", "阶层"))
	name_label.tooltip_text = String(data.get("status", ""))
	(refs.get("population") as Label).text = String(data.get("population", ""))
	(refs.get("wealth") as Label).text = String(data.get("wealth", "")).trim_prefix("人均 ")
	var card_net_label := refs.get("net") as Label
	card_net_label.text = String(data.get("net", "—"))
	card_net_label.add_theme_color_override(
		"font_color", UITokens.GOOD if bool(data.get("net_positive", true)) else UITokens.RISK)
	var finance: Dictionary = refs.get("finance", {})
	(finance.get("income") as Label).text = String(data.get("income", "+—"))
	(finance.get("expense") as Label).text = String(data.get("expense", "−—"))
	var net_text := String(data.get("net", "—"))
	var net_label := finance.get("net") as Label
	net_label.text = net_text
	net_label.add_theme_color_override("font_color", UITokens.GOOD if bool(data.get("net_positive", true)) else UITokens.RISK)
	_sync_ledger_rows(refs.get("income_group", {}), data.get("income_rows", []))
	_sync_ledger_rows(refs.get("expense_group", {}), data.get("expense_rows", []))
	var demand: Dictionary = refs.get("demand", {})
	var demand_data: Dictionary = data.get("demand_summary", {})
	(demand.get("value") as Label).text = String(demand_data.get("value", ""))
	(demand.get("subtitle") as Label).text = String(demand_data.get("subtitle", ""))
	(demand.get("panel") as Control).visible = not demand_data.is_empty()
	(demand.get("button") as Button).disabled = (data.get("demand_rows", []) as Array).is_empty()
	set_expanded(row_id, bool(_expanded.get(row_id, false)))
