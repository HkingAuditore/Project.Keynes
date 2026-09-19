extends BoxContainer
class_name SetupFieldRow


func configure(label_text: String, hint_text: String, control: Control,
		mobile_layout: bool) -> void:
	add_to_group("world_setup_field_rows")
	set_mobile_layout(mobile_layout)
	var label_box := get_node("LabelBox") as VBoxContainer
	var title_label := get_node("LabelBox/Title") as Label
	var hint_label := get_node("LabelBox/Hint") as Label
	var control_host := get_node("ControlHost") as MarginContainer
	title_label.text = label_text
	title_label.add_theme_font_size_override("font_size", 18 if mobile_layout else 16)
	hint_label.text = hint_text
	hint_label.visible = not hint_text.is_empty()
	hint_label.add_theme_font_size_override("font_size", 14 if mobile_layout else 12)
	label_box.tooltip_text = hint_text
	control.tooltip_text = hint_text
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control_host.add_child(control)


func set_mobile_layout(mobile_layout: bool) -> void:
	vertical = mobile_layout
	add_theme_constant_override("separation", 6 if mobile_layout else 14)
	var label_box := get_node("LabelBox") as VBoxContainer
	label_box.custom_minimum_size.x = 0.0 if mobile_layout else 320.0
	(get_node("LabelBox/Title") as Label).add_theme_font_size_override(
		"font_size", 18 if mobile_layout else 16)
	(get_node("LabelBox/Hint") as Label).add_theme_font_size_override(
		"font_size", 14 if mobile_layout else 12)
