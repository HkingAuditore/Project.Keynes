extends VBoxContainer

const Categories = preload("res://scripts/narrative/narrative_pause_categories.gd")
var _choices: Array[CheckBox] = []
var _notices: Array[CheckBox] = []


func _ready() -> void:
	var title := UIControlParts.label()
	title.text = "事件暂停"
	title.theme_type_variation = &"PKSectionTitle"
	add_child(title)

	var grid := UIControlParts.grid_container()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	add_child(grid)
	for text_value in ["类别", "有选择时", "仅通知时"]:
		var heading := UIControlParts.label()
		heading.text = text_value
		heading.theme_type_variation = &"PKMutedLabel"
		grid.add_child(heading)

	for category: String in Categories.NAMES:
		var label := UIControlParts.label()
		label.text = category
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(label)
		for is_notice in [false, true]:
			var controls := _notices if is_notice else _choices
			var button := UIControlParts.check_box()
			button.text = "暂停"
			button.custom_minimum_size.y = 44
			button.tooltip_text = category + ("仅通知时暂停" if is_notice else "有选择时暂停")
			grid.add_child(button)
			controls.append(button)


func configure(mask: int) -> void:
	var count := Categories.NAMES.size()
	for i in range(count):
		_choices[i].set_pressed_no_signal(mask & (1 << i) != 0)
		_notices[i].set_pressed_no_signal(mask & (1 << (count + i)) != 0)


func value() -> int:
	var mask := 0
	var count := Categories.NAMES.size()
	for i in range(count):
		if _choices[i].button_pressed:
			mask |= 1 << i
		if _notices[i].button_pressed:
			mask |= 1 << (count + i)
	return mask
