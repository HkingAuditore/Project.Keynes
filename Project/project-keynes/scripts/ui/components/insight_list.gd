extends VBoxContainer
class_name InsightList


func set_items(items: Array) -> void:
	for child in get_children():
		child.queue_free()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	for raw in items:
		var data: Dictionary = raw
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UITokens.SPACE_SM)
		var accent: Color = data.get("accent", UITokens.ACCENT)
		var mark := Label.new()
		mark.text = String(data.get("icon", "•"))
		mark.custom_minimum_size = Vector2(18.0, 20.0)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.add_theme_color_override("font_color", accent)
		row.add_child(mark)
		var label := Label.new()
		label.text = String(data.get("text", ""))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
		row.add_child(label)
		add_child(row)
