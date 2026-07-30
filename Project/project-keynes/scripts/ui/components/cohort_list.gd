extends VBoxContainer
class_name CohortList

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
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_SM)
	panel.add_child(body)

	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, 58.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = ""
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "cohort", "row_id": row_id,
			"profession_id": String((_row_data.get(row_id, {}) as Dictionary) \
				.get("profession_id", ""))}))
	body.add_child(button)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 7)
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	button.add_child(header)
	var chevron := Button.new()
	chevron.toggle_mode = true
	chevron.custom_minimum_size = Vector2(22.0, 22.0)
	chevron.focus_mode = Control.FOCUS_NONE
	chevron.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chevron.tooltip_text = "展开 / 折叠"
	chevron.toggled.connect(func(expanded: bool) -> void: set_expanded(row_id, expanded))
	header.add_child(chevron)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(26.0, 26.0)
	header.add_child(icon)
	var identity := VBoxContainer.new()
	identity.custom_minimum_size.x = 0.0
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 0)
	header.add_child(identity)
	var name_label := Label.new()
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	identity.add_child(name_label)
	var status_label := Label.new()
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	status_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	identity.add_child(status_label)
	var living_icon := IconBadge.new()
	living_icon.custom_minimum_size = Vector2(22.0, 22.0)
	header.add_child(living_icon)
	living_icon.mouse_filter = Control.MOUSE_FILTER_STOP
	var population_label := Label.new()
	population_label.custom_minimum_size = Vector2(54.0, 0.0)
	population_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	population_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	population_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	header.add_child(population_label)
	var wealth_label := Label.new()
	wealth_label.custom_minimum_size = Vector2(62.0, 0.0)
	wealth_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	wealth_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	wealth_label.add_theme_color_override("font_color", UITokens.RESOURCE)
	header.add_child(wealth_label)
	var ledger := VBoxContainer.new()
	ledger.custom_minimum_size = Vector2(102.0, 0.0)
	ledger.add_theme_constant_override("separation", 0)
	header.add_child(ledger)
	var income_label := Label.new()
	income_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	income_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	income_label.add_theme_color_override("font_color", UITokens.GOOD)
	ledger.add_child(income_label)
	var expense_label := Label.new()
	expense_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	expense_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	expense_label.add_theme_color_override("font_color", UITokens.RISK)
	ledger.add_child(expense_label)

	var details := VBoxContainer.new()
	details.visible = false
	details.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(details)
	var finance := _create_finance_summary(details)
	var income_group := _create_ledger_group(details, "收入构成", "trend_up", UITokens.GOOD)
	var expense_group := _create_ledger_group(details, "支出构成", "trend_down", UITokens.RISK)
	var demand := _create_demand_summary(details, row_id)

	var refs := {"panel": panel, "button": button, "chevron": chevron, "icon": icon,
		"living_icon": living_icon, "name": name_label,
		"status": status_label, "population": population_label, "wealth": wealth_label,
		"income": income_label, "expense": expense_label, "details": details,
		"finance": finance, "income_group": income_group,
		"expense_group": expense_group, "demand": demand}
	_apply_row(row_id, refs, data)
	return refs


func _create_finance_summary(parent: VBoxContainer) -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.045, 0.039, 0.032, 0.98), UITokens.PANEL_BORDER_SOFT))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	margin.add_child(grid)
	var refs := {}
	for key in ["income", "expense", "net"]:
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 0)
		grid.add_child(box)
		var label := Label.new()
		label.text = {"income": "收入", "expense": "支出", "net": "净额"}[key]
		label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		box.add_child(label)
		var value := Label.new()
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color", UITokens.GOOD if key == "income" else UITokens.RISK)
		box.add_child(value)
		refs[key] = value
	return refs


func _create_ledger_group(parent: VBoxContainer, title: String, icon_key: String, accent: Color) -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.040, 0.035, 0.029, 0.98), Color(accent.r, accent.g, accent.b, 0.34)))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	box.add_child(title_row)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(18.0, 18.0)
	icon.set_semantic(StringName(icon_key), accent)
	title_row.add_child(icon)
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	title_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	title_label.add_theme_color_override("font_color", accent)
	title_row.add_child(title_label)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	box.add_child(rows)
	return {"panel": panel, "rows": rows, "refs": {}, "accent": accent}


func _create_demand_summary(parent: VBoxContainer, row_id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.040, 0.035, 0.029, 0.98), Color(UITokens.RESOURCE.r, UITokens.RESOURCE.g, UITokens.RESOURCE.b, 0.30)))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	var title := Label.new()
	title.text = "消费需求"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_override("font", UITokens.font_with_weight(650))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	title.add_theme_color_override("font_color", UITokens.RESOURCE)
	top.add_child(title)
	var value := Label.new()
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	top.add_child(value)
	var details_button := Button.new()
	details_button.custom_minimum_size = Vector2(30.0, 28.0)
	details_button.focus_mode = Control.FOCUS_NONE
	details_button.tooltip_text = "查看消费需求明细"
	IconButton.apply(details_button, &"summary.overview", 13, "查看消费需求明细")
	details_button.pressed.connect(func() -> void: _request_demand_details(row_id))
	top.add_child(details_button)
	var subtitle := Label.new()
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subtitle.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	subtitle.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	box.add_child(subtitle)
	return {"panel": panel, "value": value, "subtitle": subtitle, "button": details_button}


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
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", UITokens.SPACE_SM)
			container.add_child(line)
			var name_label := Label.new()
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
			name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			line.add_child(name_label)
			var value_label := Label.new()
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
			value_label.add_theme_color_override("font_color", group.get("accent", UITokens.TEXT_MAIN))
			line.add_child(value_label)
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
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.055, 0.048, 0.039, 0.96), Color(accent.r, accent.g, accent.b, 0.42)))
	(refs.get("icon") as IconBadge).set_semantic(
		StringName(data.get("icon", &"ecology.growth")), accent)
	var living_accent: Color = data.get("living_accent", UITokens.TEXT_MUTED)
	var living_badge := refs.get("living_icon") as IconBadge
	living_badge.set_semantic(
		StringName(data.get("living_icon", &"action.history")), living_accent)
	living_badge.tooltip_text = "%s · 满意度 %s" % [
		String(data.get("living_standard", "待评估")),
		String(data.get("satisfaction", "—"))]
	(refs.get("name") as Label).text = String(data.get("name", "阶层"))
	(refs.get("status") as Label).text = String(data.get("status", ""))
	(refs.get("population") as Label).text = String(data.get("population", ""))
	(refs.get("wealth") as Label).text = String(data.get("wealth", ""))
	(refs.get("income") as Label).text = "收入 %s" % String(data.get("income", "+—"))
	(refs.get("expense") as Label).text = "支出 %s" % String(data.get("expense", "−—"))
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
