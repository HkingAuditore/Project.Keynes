extends HBoxContainer
class_name CategoryTabs

const TabButtonScene := preload("res://scenes/ui/category_tab_button.tscn")

signal tab_selected(tab_id: String)

var _current_tab: String = ""
var _buttons: Dictionary = {}


func set_tabs(tabs: Array, current_tab: String = "", show_labels: bool = false) -> void:
	clear_tabs()
	if tabs.is_empty():
		return
	_current_tab = current_tab if current_tab != "" else String(tabs[0].get("id", ""))
	for tab in tabs:
		var data: Dictionary = tab
		var id := String(data.get("id", ""))
		var label := String(data.get("label", id))
		var icon_key := IconBadge.normalize_icon(String(data.get("icon", id)))
		var btn := TabButtonScene.instantiate() as Button
		btn.text = label if show_labels else ""
		btn.tooltip_text = String(data.get("tooltip", label))
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.custom_minimum_size = Vector2(0.0, 34.0) if show_labels else Vector2(54.0, 34.0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var icon_center := btn.get_node("IconCenter") as CenterContainer
		var icon := btn.get_node("IconCenter/Icon") as IconBadge
		if show_labels:
			btn.custom_minimum_size = Vector2(0.0, 34.0)
			btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			icon_center.anchor_right = 0.0
			icon_center.offset_left = 6.0
			icon_center.offset_right = 30.0
		icon.set_semantic(StringName(icon_key), UITokens.ACCENT)
		btn.set_pressed_no_signal(id == _current_tab)
		btn.pressed.connect(_on_tab_pressed.bind(id))
		add_child(btn)
		_buttons[id] = btn


func current_tab() -> String:
	return _current_tab


func select_tab(tab_id: String) -> void:
	if not _buttons.has(tab_id):
		return
	_current_tab = tab_id
	for key in _buttons.keys():
		var button := _buttons[key] as Button
		if button != null:
			button.set_pressed_no_signal(String(key) == tab_id)


func clear_tabs() -> void:
	for child in get_children():
		child.queue_free()
	_buttons.clear()
	_current_tab = ""


func _on_tab_pressed(tab_id: String) -> void:
	select_tab(tab_id)
	tab_selected.emit(tab_id)
