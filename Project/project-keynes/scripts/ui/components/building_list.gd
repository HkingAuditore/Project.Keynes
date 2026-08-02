extends VBoxContainer
class_name BuildingList

const BuildingRowScene := preload("res://scenes/ui/building_row.tscn")
const BuildingDetailRowScene := preload("res://scenes/ui/building_detail_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _expanded: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_expanded.clear()
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "building_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id, data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for refs in _row_refs.values():
		((refs as Dictionary).get("panel") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id, data)
		_apply_row(row_id, _row_refs[row_id], data)


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id):
		return
	_expanded[row_id] = expanded
	var refs: Dictionary = _row_refs[row_id]
	var chevron := refs.get("chevron") as Button
	IconButton.apply(chevron,
		&"action.chevron_down" if expanded else &"action.chevron_right",
		IconButton.SMALL, "展开 / 折叠", true, expanded)
	(refs.get("details") as Control).visible = expanded


func is_expanded(row_id: String) -> bool:
	return bool(_expanded.get(row_id, false))


func _create_row(row_id: String, data: Dictionary) -> Dictionary:
	var panel := BuildingRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.pressed.connect(func() -> void:
		details_requested.emit({"kind": "building", "row_id": row_id}))
	var chevron := panel.get_node("Body/Button/Header/Chevron") as Button
	chevron.toggled.connect(func(expanded: bool) -> void:
		set_expanded(row_id, expanded))
	var jobs := _rows_card_refs(panel, "Jobs", true, UITokens.ACCENT)
	var production := _rows_card_refs(panel, "Production", false, UITokens.RESOURCE)
	(jobs.icon as IconBadge).set_semantic(&"population.growth", UITokens.ACCENT)
	(production.icon as IconBadge).set_semantic(&"economy.resource", UITokens.RESOURCE)
	var finance_values := {
		"revenue": panel.get_node("Body/Details/Finance/Box/Grid/Revenue/Value"),
		"cost": panel.get_node("Body/Details/Finance/Box/Grid/Cost/Value"),
		"profit": panel.get_node("Body/Details/Finance/Box/Grid/Profit/Value"),
	}
	var refs := {
		"panel": panel, "button": button, "chevron": chevron,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"name": panel.get_node("Body/Button/Header/Identity/NameRow/Name"),
		"state_icon": panel.get_node("Body/Button/Header/Identity/NameRow/StateIcon"),
		"owner": panel.get_node("Body/Button/Header/Identity/Owner"),
		"count": panel.get_node("Body/Button/Header/Count"),
		"profit_label": panel.get_node("Body/Button/Header/ProfitBox/Label"),
		"profit": panel.get_node("Body/Button/Header/ProfitBox/Value"),
		"details": panel.get_node("Body/Details"),
		"state_summary": {
			"panel": panel.get_node("Body/Details/StateSummary"),
			"label": panel.get_node("Body/Details/StateSummary/Box/Label"),
			"detail": panel.get_node("Body/Details/StateSummary/Box/Detail"),
			"meta": panel.get_node("Body/Details/StateSummary/Box/Meta"),
		},
		"jobs": jobs, "production": production,
		"finance": {
			"panel": panel.get_node("Body/Details/Finance"), "values": finance_values,
			"breakdown": panel.get_node("Body/Details/Finance/Box/Breakdown"),
			"warning": panel.get_node("Body/Details/Finance/Box/Warning"),
		},
	}
	_apply_row(row_id, refs, data)
	return refs


func _rows_card_refs(panel: PanelContainer, node_name: String,
		show_progress: bool, accent: Color) -> Dictionary:
	var base := "Body/Details/%s/Box" % node_name
	return {
		"panel": panel.get_node("Body/Details/%s" % node_name),
		"icon": panel.get_node("%s/TitleRow/Icon" % base),
		"rows": panel.get_node("%s/Rows" % base),
		"refs": {}, "accent": accent, "show_progress": show_progress,
	}


func _sync_rows_card(card: Dictionary, rows: Array) -> void:
	var container := card.get("rows") as VBoxContainer
	var refs: Dictionary = card.get("refs", {})
	for ref in refs.values():
		((ref as Dictionary).get("root") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "row_%d" % refs.size()))
		if not refs.has(row_id):
			var root := BuildingDetailRowScene.instantiate() as VBoxContainer
			container.add_child(root)
			var progress := root.get_node("Progress") as ProgressBar
			progress.visible = bool(card.get("show_progress", false))
			refs[row_id] = {"root": root, "name": root.get_node("Line/Name"),
				"value": root.get_node("Line/Value"), "progress": progress}
		var ref: Dictionary = refs[row_id]
		(ref.root as Control).visible = bool(data.get("visible", true))
		(ref.name as Label).text = String(data.get("name", ""))
		(ref.value as Label).text = String(data.get("value", ""))
		var progress := ref.progress as ProgressBar
		if progress.visible:
			progress.value = clampf(float(data.get("ratio", 0.0)) * 100.0, 0.0, 100.0)
	card["refs"] = refs
	(card.get("panel") as Control).visible = not rows.is_empty()


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	(refs.panel as Control).visible = bool(data.get("visible", true))
	(refs.icon as IconBadge).set_semantic(
		StringName(data.get("icon", &"economy.building")), accent)
	(refs.name as Label).text = String(data.get("name", "建筑"))
	(refs.owner as Label).text = String(data.get("owner", ""))
	(refs.count as Label).text = String(data.get("count", ""))
	(refs.profit_label as Label).text = String(data.get("profit_label", "利润"))
	(refs.profit as Label).text = String(data.get("profit", ""))
	(refs.profit as Label).add_theme_color_override("font_color", accent)
	var state: Dictionary = data.get("state_summary", {})
	var state_refs: Dictionary = refs.state_summary
	var state_accent: Color = state.get("accent", UITokens.WARN)
	(refs.state_icon as IconBadge).set_semantic(StringName(state.get("icon", &"")), state_accent)
	(refs.state_icon as Control).tooltip_text = String(state.get("label", ""))
	(state_refs.panel as Control).visible = not state.is_empty()
	if not state.is_empty():
		(state_refs.label as Label).text = String(state.get("label", "经营状态"))
		(state_refs.label as Label).add_theme_color_override("font_color", state_accent)
		(state_refs.detail as Label).text = String(state.get("detail", ""))
		(state_refs.meta as Label).text = String(state.get("meta", ""))
		(state_refs.meta as Control).visible = not (state_refs.meta as Label).text.is_empty()
	_sync_rows_card(refs.jobs, data.get("job_rows", []))
	_sync_rows_card(refs.production, data.get("production_rows", []))
	var finance: Dictionary = data.get("finance", {})
	var finance_refs: Dictionary = refs.finance
	(finance_refs.panel as Control).visible = not finance.is_empty()
	var values: Dictionary = finance_refs.values
	(values.revenue as Label).text = String(finance.get("revenue", "—"))
	(values.revenue as Label).add_theme_color_override("font_color", UITokens.GOOD)
	(values.cost as Label).text = String(finance.get("cost", "—"))
	(values.cost as Label).add_theme_color_override("font_color", UITokens.RISK)
	(values.profit as Label).text = String(finance.get("profit", "—"))
	(values.profit as Label).add_theme_color_override("font_color",
		UITokens.GOOD if bool(finance.get("profit_positive", true)) else UITokens.RISK)
	(finance_refs.breakdown as Label).text = String(finance.get("breakdown", ""))
	(finance_refs.warning as Label).text = String(finance.get("warning", ""))
	(finance_refs.warning as Control).visible = not (finance_refs.warning as Label).text.is_empty()
	set_expanded(row_id, bool(_expanded.get(row_id, false)))
