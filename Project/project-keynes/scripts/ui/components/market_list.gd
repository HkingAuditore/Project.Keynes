extends VBoxContainer
class_name MarketList

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _expanded: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_expanded.clear()
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	var active_rows: Dictionary = {}
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		active_rows[row_id] = true
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id)
		_apply_row(row_id, _row_refs[row_id], data)
	for row_id in _row_refs.keys():
		if active_rows.has(row_id):
			continue
		var refs: Dictionary = _row_refs[row_id]
		var panel := refs.get("panel") as PanelContainer
		if panel != null and panel.visible:
			panel.visible = false


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id):
		return
	_expanded[row_id] = expanded
	var refs: Dictionary = _row_refs[row_id]
	if expanded:
		_sync_details(refs, refs.get("detail_rows", []))
	var chevron := refs.get("chevron") as Button
	if chevron != null:
		IconButton.apply(chevron,
			&"action.chevron_down" if expanded else &"action.chevron_right",
			IconButton.SMALL, "展开 / 折叠", true, expanded)
	var details := refs.get("details") as Control
	if details.visible != expanded:
		details.visible = expanded


func is_expanded(row_id: String) -> bool:
	return bool(_expanded.get(row_id, false))


func _create_row(row_id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_XS)
	panel.add_child(body)
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, 54.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = ""
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "good", "row_id": row_id}))
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
	risk_label.add_theme_color_override("font_color", UITokens.RISK)
	header.add_child(risk_label)
	var details := VBoxContainer.new()
	details.visible = false
	details.add_theme_constant_override("separation", 2)
	body.add_child(details)
	var refs := {"panel": panel, "button": button, "chevron": chevron, "icon": icon, "name": name_label,
		"stock": stock_label, "price": price_label, "delta": delta_label,
		"risk": risk_label, "details": details, "detail_refs": {},
		"detail_rows": [], "applied": {}}
	return refs


func _sync_details(refs: Dictionary, rows: Array) -> void:
	var details := refs.get("details") as VBoxContainer
	var detail_refs: Dictionary = refs.get("detail_refs", {})
	var active_details: Dictionary = {}
	for raw in rows:
		var data: Dictionary = raw
		var detail_id := String(data.get("id", "detail_%d" % detail_refs.size()))
		active_details[detail_id] = true
		if not detail_refs.has(detail_id):
			detail_refs[detail_id] = _create_detail(details)
		_apply_detail(detail_refs[detail_id], data)
	for detail_id in detail_refs.keys():
		if active_details.has(detail_id):
			continue
		var detail: Dictionary = detail_refs[detail_id]
		var root := detail.get("root") as Control
		if root.visible:
			root.visible = false
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
	var applied: Dictionary = refs.get("applied", {})
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var panel := refs.get("panel") as PanelContainer
	var row_visible := bool(data.get("visible", true))
	if panel.visible != row_visible:
		panel.visible = row_visible
	if not applied.has("accent") or applied["accent"] != accent:
		panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
			Color(0.052, 0.046, 0.038, 0.96), Color(accent.r, accent.g, accent.b, 0.38)))
	var icon_key := String(data.get("icon", "resource"))
	if not applied.has("icon") or applied["icon"] != icon_key \
			or not applied.has("accent") or applied["accent"] != accent:
		(refs.get("icon") as IconBadge).set_semantic(StringName(icon_key), accent)
	var name_text := String(data.get("name", "商品"))
	var name_label := refs.get("name") as Label
	if name_label.text != name_text:
		name_label.text = name_text
	var stock_text := String(data.get("stock", ""))
	var stock_label := refs.get("stock") as Label
	if stock_label.text != stock_text:
		stock_label.text = stock_text
	var price_text := String(data.get("price", ""))
	var price_label := refs.get("price") as Label
	if price_label.text != price_text:
		price_label.text = price_text
	var delta := String(data.get("delta", "—"))
	var delta_label := refs.get("delta") as Label
	if delta_label.text != delta:
		delta_label.text = delta
	var delta_color := UITokens.GOOD if delta.begins_with("+") \
		else (UITokens.RISK if delta.begins_with("-") else UITokens.TEXT_MUTED)
	if not applied.has("delta_color") or applied["delta_color"] != delta_color:
		delta_label.add_theme_color_override("font_color", delta_color)
	var risk := String(data.get("risk", ""))
	var risk_label := refs.get("risk") as Label
	if risk_label.text != risk:
		risk_label.text = risk
	# 折叠行只缓存最新详情；展开时才创建/更新详情节点，避免日更遍历整张商品明细表。
	var detail_rows: Array = data.get("detail_rows", [])
	refs["detail_rows"] = detail_rows
	set_expanded(row_id, bool(_expanded.get(row_id, false)))
	applied["accent"] = accent
	applied["icon"] = icon_key
	applied["delta_color"] = delta_color
	refs["applied"] = applied


func _apply_detail(refs: Dictionary, data: Dictionary) -> void:
	var root := refs.get("root") as Control
	var detail_visible := bool(data.get("visible", true))
	if root.visible != detail_visible:
		root.visible = detail_visible
	var name_text := String(data.get("name", ""))
	var name_label := refs.get("name") as Label
	if name_label.text != name_text:
		name_label.text = name_text
	var value_text := String(data.get("value", ""))
	var value_label := refs.get("value") as Label
	if value_label.text != value_text:
		value_label.text = value_text
