extends VBoxContainer
class_name ResourceList

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	add_theme_constant_override("separation", 4)
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "resource_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(data)
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
			_row_refs[row_id] = _create_row(data)
		_apply_row(_row_refs[row_id], data)


func _create_row(data: Dictionary) -> Dictionary:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0.0, 36.0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(panel)

	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.text = ""
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "resource", "row_id": String(data.get("id", ""))}))
	panel.add_child(button)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 3)
	button.add_child(margin)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)

	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(24.0, 24.0)
	line.add_child(icon)

	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(name_label)

	var density_label := Label.new()
	density_label.custom_minimum_size = Vector2(40.0, 0.0)
	density_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	density_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	line.add_child(density_label)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(86.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	line.add_child(value_label)

	var delta_label := Label.new()
	delta_label.custom_minimum_size = Vector2(70.0, 0.0)
	delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	delta_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	delta_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	delta_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	line.add_child(delta_label)

	var refs := {
		"panel": panel,
		"button": button,
		"icon": icon,
		"name": name_label,
		"density": density_label,
		"value": value_label,
		"delta": delta_label,
	}
	_apply_row(refs, data)
	return refs


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	panel.add_theme_stylebox_override(
		"panel",
		UITokens.inset_panel_style(
			Color(0.062, 0.054, 0.043, 0.94),
			Color(accent.r, accent.g, accent.b, 0.40)
		)
	)
	var icon := refs.get("icon") as IconBadge
	icon.set_semantic(StringName(data.get("icon", &"economy.resource")), accent)
	var name_label := refs.get("name") as Label
	name_label.text = String(data.get("name", "资源"))
	var density_label := refs.get("density") as Label
	density_label.text = String(data.get("density", ""))
	density_label.add_theme_color_override("font_color", accent.lerp(UITokens.TEXT_MAIN, 0.18))
	var value_label := refs.get("value") as Label
	value_label.text = String(data.get("value", ""))
	var delta_label := refs.get("delta") as Label
	delta_label.text = String(data.get("delta", ""))
	var delta_text := delta_label.text
	delta_label.add_theme_color_override(
		"font_color",
		UITokens.GOOD if delta_text.contains("+") else (UITokens.RISK if delta_text.contains("-") else UITokens.TEXT_MUTED)
	)
