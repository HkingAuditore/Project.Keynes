extends VBoxContainer
class_name ResourceList


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	add_theme_constant_override("separation", 4)
	for raw in rows:
		var data: Dictionary = raw
		_add_row(data)


func _add_row(data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 34.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row_style := UITokens.panel_style(Color(0.105, 0.080, 0.052, 0.92), UITokens.RADIUS_SM, Color(accent.r, accent.g, accent.b, 0.30))
	row_style.content_margin_left = 0
	row_style.content_margin_top = 0
	row_style.content_margin_right = 0
	row_style.content_margin_bottom = 0
	row.add_theme_stylebox_override("panel", row_style)
	add_child(row)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 2)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 2)
	row.add_child(margin)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(line)

	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(24.0, 24.0)
	icon.set_icon(String(data.get("icon", "resource")), accent)
	line.add_child(icon)

	var name_label := Label.new()
	name_label.text = String(data.get("name", "资源"))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(name_label)

	var density_label := Label.new()
	density_label.text = String(data.get("density", ""))
	density_label.custom_minimum_size = Vector2(44.0, 0.0)
	density_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	density_label.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b, 0.96))
	line.add_child(density_label)

	var value_label := Label.new()
	value_label.text = String(data.get("value", ""))
	value_label.custom_minimum_size = Vector2(92.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	line.add_child(value_label)

	var delta_label := Label.new()
	delta_label.text = String(data.get("delta", ""))
	delta_label.custom_minimum_size = Vector2(76.0, 0.0)
	delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	delta_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	line.add_child(delta_label)
