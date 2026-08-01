extends VBoxContainer
class_name FamilyList

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	add_theme_constant_override("separation", 4)
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "family_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for refs_value in _row_refs.values():
		var refs: Dictionary = refs_value
		var button := refs.get("button") as Button
		if button != null:
			button.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id)
		_apply_row(_row_refs[row_id], data)


func _create_row(row_id: String) -> Dictionary:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.text = ""
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "family", "row_id": row_id}))
	add_child(button)
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, UITokens.SPACE_SM)
	button.add_child(margin)
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_BEGIN
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(24.0, 24.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(icon)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(name_label)
	return {"button": button, "icon": icon, "name": name_label}


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var button := refs.get("button") as Button
	button.visible = true
	button.add_theme_stylebox_override("normal", UITokens.button_style(
		Color(0.050, 0.044, 0.036, 0.92), Color(accent.r, accent.g, accent.b, 0.42)))
	button.add_theme_stylebox_override("hover", UITokens.button_style(
		Color(0.075, 0.063, 0.047, 0.98), Color(accent.r, accent.g, accent.b, 0.78)))
	button.add_theme_stylebox_override("pressed", UITokens.button_style(
		Color(0.038, 0.034, 0.029, 0.99), accent, UITokens.RADIUS_SM, true))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	(refs.get("icon") as IconBadge).set_semantic(&"family.house", accent)
	(refs.get("name") as Label).text = String(data.get("name", "家族"))
