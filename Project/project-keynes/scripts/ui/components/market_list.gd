extends VBoxContainer
class_name MarketList

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
		var row_id := String(data.get("id", "market_%d" % _row_refs.size()))
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
	body.add_theme_constant_override("separation", UITokens.SPACE_XS)
	panel.add_child(body)
	var button := Button.new()
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, 54.0)
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
	var stock_label := Label.new()
	stock_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stock_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	stock_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	identity.add_child(stock_label)
	var price_box := VBoxContainer.new()
	price_box.custom_minimum_size = Vector2(92.0, 0.0)
	price_box.add_theme_constant_override("separation", 0)
	header.add_child(price_box)
	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.add_theme_color_override("font_color", UITokens.RESOURCE)
	price_box.add_child(price_label)
	var delta_label := Label.new()
	delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	delta_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	price_box.add_child(delta_label)
	var risk_label := Label.new()
	risk_label.custom_minimum_size = Vector2(46.0, 0.0)
	risk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	risk_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	header.add_child(risk_label)
	var details := VBoxContainer.new()
	details.visible = false
	details.add_theme_constant_override("separation", 2)
	body.add_child(details)
	var refs := {"panel": panel, "button": button, "icon": icon, "name": name_label,
		"stock": stock_label, "price": price_label, "delta": delta_label,
		"risk": risk_label, "details": details, "detail_refs": {}}
	_sync_details(refs, data.get("detail_rows", []))
	_apply_row(row_id, refs, data)
	return refs


func _sync_details(refs: Dictionary, rows: Array) -> void:
	var details := refs.get("details") as VBoxContainer
	var detail_refs: Dictionary = refs.get("detail_refs", {})
	for ref in detail_refs.values():
		((ref as Dictionary).get("root") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var detail_id := String(data.get("id", "detail_%d" % detail_refs.size()))
		if not detail_refs.has(detail_id):
			detail_refs[detail_id] = _create_detail(details)
		_apply_detail(detail_refs[detail_id], data)
	refs["detail_refs"] = detail_refs


func _create_detail(parent: VBoxContainer) -> Dictionary:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	parent.add_child(margin)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)
	var name_label := Label.new()
	name_label.custom_minimum_size.x = 0.0
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	line.add_child(name_label)
	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(value_label)
	return {"root": margin, "name": name_label, "value": value_label}


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.052, 0.046, 0.038, 0.96), Color(accent.r, accent.g, accent.b, 0.38)))
	(refs.get("icon") as IconBadge).set_icon(String(data.get("icon", "resource")), accent)
	(refs.get("name") as Label).text = String(data.get("name", "商品"))
	(refs.get("stock") as Label).text = String(data.get("stock", ""))
	(refs.get("price") as Label).text = String(data.get("price", ""))
	var delta := String(data.get("delta", "—"))
	(refs.get("delta") as Label).text = delta
	(refs.get("delta") as Label).add_theme_color_override("font_color",
		UITokens.GOOD if delta.begins_with("+") else (UITokens.RISK if delta.begins_with("-") else UITokens.TEXT_MUTED))
	var risk := String(data.get("risk", ""))
	(refs.get("risk") as Label).text = risk
	(refs.get("risk") as Label).add_theme_color_override("font_color", UITokens.RISK)
	_sync_details(refs, data.get("detail_rows", []))
	set_expanded(row_id, bool(_expanded.get(row_id, false)))


func _apply_detail(refs: Dictionary, data: Dictionary) -> void:
	(refs.get("root") as Control).visible = bool(data.get("visible", true))
	(refs.get("name") as Label).text = String(data.get("name", ""))
	(refs.get("value") as Label).text = String(data.get("value", ""))
