extends VBoxContainer
class_name CohortList

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
		var row_id := String(data.get("id", "cohort_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id, data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for row_id in _row_refs.keys():
		var refs: Dictionary = _row_refs[row_id]
		var panel := refs.get("panel") as PanelContainer
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
	var button := refs.get("button") as Button
	var details := refs.get("details") as Control
	if button != null:
		button.set_pressed_no_signal(expanded)
	if details != null:
		details.visible = expanded


func is_expanded(row_id: String) -> bool:
	return bool(_expanded.get(row_id, false))


func _create_row(row_id: String, data: Dictionary) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(panel)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_XS)
	panel.add_child(body)

	var button := Button.new()
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, 52.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = ""
	button.toggled.connect(func(expanded: bool) -> void:
		set_expanded(row_id, expanded)
	)
	body.add_child(button)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(header)
	header.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)

	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(24.0, 24.0)
	header.add_child(icon)

	var identity := VBoxContainer.new()
	identity.custom_minimum_size = Vector2(78.0, 0.0)
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

	var population_label := Label.new()
	population_label.custom_minimum_size = Vector2(58.0, 0.0)
	population_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	population_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	population_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	header.add_child(population_label)

	var wealth_label := Label.new()
	wealth_label.custom_minimum_size = Vector2(66.0, 0.0)
	wealth_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	wealth_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	wealth_label.add_theme_color_override("font_color", UITokens.RESOURCE)
	header.add_child(wealth_label)

	var ledger := VBoxContainer.new()
	ledger.custom_minimum_size = Vector2(86.0, 0.0)
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
	details.add_theme_constant_override("separation", 2)
	body.add_child(details)
	var detail_refs := {}
	_sync_detail_rows(details, detail_refs, data.get("detail_rows", []))
	_sync_detail_rows(details, detail_refs, data.get("demand_rows", []))

	var refs := {
		"panel": panel,
		"button": button,
		"icon": icon,
		"name": name_label,
		"status": status_label,
		"population": population_label,
		"wealth": wealth_label,
		"income": income_label,
		"expense": expense_label,
		"details": details,
		"details_by_id": detail_refs,
	}
	_apply_row(row_id, refs, data)
	return refs


func _sync_detail_rows(parent: VBoxContainer, refs: Dictionary, rows: Array) -> void:
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "detail_%d" % refs.size()))
		if not refs.has(row_id):
			refs[row_id] = _create_detail_row(parent, data)
		_apply_detail(refs[row_id], data)


func _create_detail_row(parent: VBoxContainer, data: Dictionary) -> Dictionary:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	parent.add_child(margin)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(18.0, 18.0)
	line.add_child(icon)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	line.add_child(name_label)
	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(value_label)
	var refs := {"root": margin, "icon": icon, "name": name_label, "value": value_label}
	_apply_detail(refs, data)
	return refs


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	panel.add_theme_stylebox_override(
		"panel",
		UITokens.inset_panel_style(Color(0.055, 0.048, 0.039, 0.96), Color(accent.r, accent.g, accent.b, 0.42))
	)
	(refs.get("icon") as IconBadge).set_icon(String(data.get("icon", "growth")), accent)
	(refs.get("name") as Label).text = String(data.get("name", "阶层"))
	(refs.get("status") as Label).text = String(data.get("status", ""))
	(refs.get("population") as Label).text = String(data.get("population", ""))
	(refs.get("wealth") as Label).text = String(data.get("wealth", ""))
	(refs.get("income") as Label).text = String(data.get("income", "+—"))
	(refs.get("expense") as Label).text = String(data.get("expense", "−—"))
	var detail_refs: Dictionary = refs.get("details_by_id", {})
	for detail_ref in detail_refs.values():
		var root := (detail_ref as Dictionary).get("root") as Control
		if root != null:
			root.visible = false
	_sync_detail_rows(refs.get("details") as VBoxContainer, detail_refs, data.get("detail_rows", []))
	_sync_detail_rows(refs.get("details") as VBoxContainer, detail_refs, data.get("demand_rows", []))
	refs["details_by_id"] = detail_refs
	set_expanded(row_id, bool(_expanded.get(row_id, false)))


func _apply_detail(refs: Dictionary, data: Dictionary) -> void:
	var root := refs.get("root") as Control
	root.visible = bool(data.get("visible", true))
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	(refs.get("icon") as IconBadge).set_icon(String(data.get("icon", "resource")), accent)
	(refs.get("name") as Label).text = String(data.get("name", "物资"))
	(refs.get("value") as Label).text = String(data.get("value", ""))
