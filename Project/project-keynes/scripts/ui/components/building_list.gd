extends VBoxContainer
class_name BuildingList

var _row_refs: Dictionary = {}
var _expanded: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_expanded.clear()
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "building_%d" % _row_refs.size()))
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
		_apply_row(row_id, _row_refs[row_id], data)


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id):
		return
	_expanded[row_id] = expanded
	var refs: Dictionary = _row_refs[row_id]
	(refs.get("button") as Button).set_pressed_no_signal(expanded)
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
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, 58.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = ""
	button.toggled.connect(func(expanded: bool) -> void: set_expanded(row_id, expanded))
	body.add_child(button)
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 7)
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	button.add_child(header)
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
	var owner_label := Label.new()
	owner_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	owner_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	owner_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	identity.add_child(owner_label)
	var count_label := Label.new()
	count_label.custom_minimum_size = Vector2(48.0, 0.0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	header.add_child(count_label)
	var profit_box := VBoxContainer.new()
	profit_box.custom_minimum_size = Vector2(78.0, 0.0)
	profit_box.add_theme_constant_override("separation", 0)
	header.add_child(profit_box)
	var profit_label := Label.new()
	profit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	profit_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	profit_box.add_child(profit_label)
	var profit_value := Label.new()
	profit_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	profit_value.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	profit_box.add_child(profit_value)

	var details := VBoxContainer.new()
	details.visible = false
	details.clip_contents = true
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(details)
	var jobs := _create_rows_card(details, "岗位配置", "growth", UITokens.ACCENT, true)
	var production := _create_rows_card(details, "生产概览", "resource", UITokens.RESOURCE, false)
	var finance := _create_finance_card(details)
	var refs := {"panel": panel, "button": button, "icon": icon, "name": name_label,
		"owner": owner_label, "count": count_label, "profit_label": profit_label,
		"profit": profit_value, "details": details, "jobs": jobs,
		"production": production, "finance": finance}
	_apply_row(row_id, refs, data)
	return refs


func _create_rows_card(parent: VBoxContainer, title_text: String, icon_key: String,
		accent: Color, show_progress: bool) -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.040, 0.035, 0.029, 0.98), Color(accent.r, accent.g, accent.b, 0.34)))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	box.add_child(title_row)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(18.0, 18.0)
	icon.set_icon(icon_key, accent)
	title_row.add_child(icon)
	var title := Label.new()
	title.text = title_text
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_override("font", UITokens.font_with_weight(650))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	title.add_theme_color_override("font_color", accent)
	title_row.add_child(title)
	var hint := Label.new()
	hint.text = "实际 / 岗位" if show_progress else "本期每栋 / 日"
	hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	title_row.add_child(hint)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	box.add_child(rows)
	return {"panel": panel, "rows": rows, "refs": {}, "accent": accent,
		"show_progress": show_progress}


func _create_finance_card(parent: VBoxContainer) -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.045, 0.039, 0.032, 0.98), Color(UITokens.RESOURCE.r, UITokens.RESOURCE.g, UITokens.RESOURCE.b, 0.34)))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	margin.add_child(box)
	var title := Label.new()
	title.text = "财务概览"
	title.add_theme_font_override("font", UITokens.font_with_weight(650))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	title.add_theme_color_override("font_color", UITokens.RESOURCE)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	box.add_child(grid)
	var values := {}
	for key in ["revenue", "cost", "profit"]:
		var metric := VBoxContainer.new()
		metric.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		metric.add_theme_constant_override("separation", 0)
		grid.add_child(metric)
		var label := Label.new()
		label.text = {"revenue": "收入", "cost": "总成本", "profit": "盈亏"}[key]
		label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		metric.add_child(label)
		var value := Label.new()
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		metric.add_child(value)
		values[key] = value
	var breakdown := Label.new()
	breakdown.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	breakdown.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	box.add_child(breakdown)
	var warning := Label.new()
	warning.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	warning.add_theme_color_override("font_color", UITokens.RISK)
	box.add_child(warning)
	return {"panel": panel, "values": values, "breakdown": breakdown, "warning": warning}


func _sync_rows_card(card: Dictionary, rows: Array) -> void:
	var container := card.get("rows") as VBoxContainer
	var refs: Dictionary = card.get("refs", {})
	for ref in refs.values():
		((ref as Dictionary).get("root") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "row_%d" % refs.size()))
		if not refs.has(row_id):
			var root := VBoxContainer.new()
			root.add_theme_constant_override("separation", 2)
			container.add_child(root)
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", UITokens.SPACE_SM)
			root.add_child(line)
			var name_label := Label.new()
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
			name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			line.add_child(name_label)
			var value_label := Label.new()
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
			value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
			line.add_child(value_label)
			var progress: ProgressBar = null
			if bool(card.get("show_progress", false)):
				progress = ProgressBar.new()
				progress.custom_minimum_size = Vector2(0.0, 4.0)
				progress.max_value = 100.0
				progress.show_percentage = false
				root.add_child(progress)
			refs[row_id] = {"root": root, "name": name_label, "value": value_label,
				"progress": progress}
		var ref: Dictionary = refs[row_id]
		(ref.get("root") as Control).visible = bool(data.get("visible", true))
		(ref.get("name") as Label).text = String(data.get("name", ""))
		(ref.get("value") as Label).text = String(data.get("value", ""))
		var progress := ref.get("progress") as ProgressBar
		if progress != null:
			progress.value = clampf(float(data.get("ratio", 0.0)) * 100.0, 0.0, 100.0)
	card["refs"] = refs
	(card.get("panel") as Control).visible = not rows.is_empty()


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.055, 0.048, 0.039, 0.96), Color(accent.r, accent.g, accent.b, 0.42)))
	(refs.get("icon") as IconBadge).set_icon(String(data.get("icon", "building")), accent)
	(refs.get("name") as Label).text = "%s · %s" % [String(data.get("name", "建筑")), String(data.get("status", ""))]
	(refs.get("owner") as Label).text = String(data.get("owner", ""))
	(refs.get("count") as Label).text = String(data.get("count", ""))
	(refs.get("profit_label") as Label).text = String(data.get("profit_label", "利润"))
	(refs.get("profit_label") as Label).add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	(refs.get("profit") as Label).text = String(data.get("profit", ""))
	(refs.get("profit") as Label).add_theme_color_override("font_color", accent)
	_sync_rows_card(refs.get("jobs", {}), data.get("job_rows", []))
	_sync_rows_card(refs.get("production", {}), data.get("production_rows", []))
	var finance_refs: Dictionary = refs.get("finance", {})
	var finance: Dictionary = data.get("finance", {})
	(finance_refs.get("panel") as Control).visible = not finance.is_empty()
	var values: Dictionary = finance_refs.get("values", {})
	(values.get("revenue") as Label).text = String(finance.get("revenue", "—"))
	(values.get("revenue") as Label).add_theme_color_override("font_color", UITokens.GOOD)
	(values.get("cost") as Label).text = String(finance.get("cost", "—"))
	(values.get("cost") as Label).add_theme_color_override("font_color", UITokens.RISK)
	(values.get("profit") as Label).text = String(finance.get("profit", "—"))
	(values.get("profit") as Label).add_theme_color_override("font_color", UITokens.GOOD if bool(finance.get("profit_positive", true)) else UITokens.RISK)
	(finance_refs.get("breakdown") as Label).text = String(finance.get("breakdown", ""))
	var warning := finance_refs.get("warning") as Label
	warning.text = String(finance.get("warning", ""))
	warning.visible = not warning.text.is_empty()
	set_expanded(row_id, bool(_expanded.get(row_id, false)))
