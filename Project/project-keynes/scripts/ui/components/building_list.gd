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
		if panel != null: panel.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty(): continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id, data)
		_apply_row(row_id, _row_refs[row_id], data)


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id): return
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
	body.add_theme_constant_override("separation", UITokens.SPACE_XS)
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
	button.add_child(header)
	header.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(26.0, 26.0)
	header.add_child(icon)
	var identity := VBoxContainer.new()
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
	var finance := VBoxContainer.new()
	finance.custom_minimum_size = Vector2(78.0, 0.0)
	finance.add_theme_constant_override("separation", 0)
	header.add_child(finance)
	var profit_label := Label.new()
	profit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	profit_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	finance.add_child(profit_label)
	var profit_value := Label.new()
	profit_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	profit_value.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	finance.add_child(profit_value)
	var details := VBoxContainer.new()
	details.visible = false
	details.clip_contents = true
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 2)
	body.add_child(details)
	var refs := {"panel": panel, "button": button, "icon": icon, "name": name_label,
		"owner": owner_label, "count": count_label, "profit_label": profit_label,
		"profit": profit_value, "details": details, "detail_refs": {}}
	_sync_details(refs, data.get("detail_rows", []))
	_apply_row(row_id, refs, data)
	return refs


func _sync_details(refs: Dictionary, rows: Array) -> void:
	var details := refs.get("details") as VBoxContainer
	var detail_refs: Dictionary = refs.get("detail_refs", {})
	for detail_ref in detail_refs.values():
		((detail_ref as Dictionary).get("root") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var detail_id := String(data.get("id", "detail_%d" % detail_refs.size()))
		if not detail_refs.has(detail_id):
			detail_refs[detail_id] = _create_detail(details)
		_apply_detail(detail_refs[detail_id], data)
	refs["detail_refs"] = detail_refs


func _create_detail(parent: VBoxContainer) -> Dictionary:
	var margin := MarginContainer.new()
	margin.clip_contents = true
	margin.custom_minimum_size.x = 0.0
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	parent.add_child(margin)
	var line := HBoxContainer.new()
	line.clip_contents = true
	line.custom_minimum_size.x = 0.0
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(18.0, 18.0)
	line.add_child(icon)
	var text_column := VBoxContainer.new()
	text_column.custom_minimum_size.x = 0.0
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.add_theme_constant_override("separation", 0)
	line.add_child(text_column)
	var name_label := Label.new()
	name_label.custom_minimum_size.x = 0.0
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	text_column.add_child(name_label)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 0.0
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	text_column.add_child(value_label)
	return {"root": margin, "icon": icon, "name": name_label, "value": value_label}


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
	_sync_details(refs, data.get("detail_rows", []))
	set_expanded(row_id, bool(_expanded.get(row_id, false)))


func _apply_detail(refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var is_section := bool(data.get("section", false))
	(refs.get("root") as Control).visible = bool(data.get("visible", true))
	(refs.get("icon") as IconBadge).set_icon(String(data.get("icon", "resource")), accent)
	var name_label := refs.get("name") as Label
	name_label.text = String(data.get("name", ""))
	name_label.add_theme_color_override("font_color", accent if is_section else UITokens.TEXT_MUTED)
	if is_section:
		name_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	var value_label := refs.get("value") as Label
	value_label.text = String(data.get("value", ""))
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED if is_section else UITokens.TEXT_MAIN)
