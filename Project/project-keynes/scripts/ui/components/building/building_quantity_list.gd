extends VBoxContainer

const RowScene := preload("res://scenes/ui/building_quantity_row.tscn")
const ChoiceScene := preload("res://scenes/ui/building_input_choice.tscn")


func set_rows(rows: Array, show_details: bool = true) -> void:
	while get_child_count() < rows.size():
		add_child(RowScene.instantiate())

	for index in get_child_count():
		var line := get_child(index) as HBoxContainer
		line.visible = index < rows.size()
		if not line.visible:
			continue
		var data: Dictionary = rows[index]
		(line.get_node("Icon") as IconBadge).set_semantic(
			StringName(data.get("icon", &"metric.goods")), UITokens.DOSSIER_INK_SOFT)
		(line.get_node("Description/Name") as Label).text = String(data.get("name", ""))
		var detail := line.get_node("Description/Detail") as Label
		detail.text = String(data.get("detail", ""))
		detail.visible = show_details and not detail.text.is_empty()
		if data.has("detail_accent"):
			detail.add_theme_color_override("font_color", data.detail_accent)
		else:
			detail.remove_theme_color_override("font_color")
		var quantity := line.get_node("Quantity") as Label
		quantity.text = String(data.get("text", ""))
		if data.has("value_accent"):
			quantity.add_theme_color_override("font_color", data.value_accent)
		else:
			quantity.remove_theme_color_override("font_color")
		_set_options(line.get_node("Description/Options"), data.get("options", []))


func _set_options(flow: HFlowContainer, options: Array) -> void:
	flow.visible = not options.is_empty()
	while flow.get_child_count() < options.size():
		flow.add_child(ChoiceScene.instantiate())
	for index in flow.get_child_count():
		var choice := flow.get_child(index) as Control
		choice.visible = index < options.size()
		if choice.visible:
			var option: Dictionary = options[index]
			(choice.get_node("Icon") as IconBadge).set_semantic(option.icon)
			(choice.get_node("Name") as Label).text = String(option.name)
