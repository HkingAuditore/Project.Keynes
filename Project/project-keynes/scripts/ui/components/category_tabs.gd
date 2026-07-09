extends HBoxContainer
class_name CategoryTabs

signal tab_selected(tab_id: String)

var _current_tab: String = ""
var _buttons: Dictionary = {}


func set_tabs(tabs: Array, current_tab: String = "") -> void:
	for child in get_children():
		child.queue_free()
	_buttons.clear()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	if tabs.is_empty():
		return
	_current_tab = current_tab if current_tab != "" else String(tabs[0].get("id", ""))
	for tab in tabs:
		var data: Dictionary = tab
		var id := String(data.get("id", ""))
		var btn := Button.new()
		btn.text = String(data.get("label", id))
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.set_pressed_no_signal(id == _current_tab)
		btn.pressed.connect(_on_tab_pressed.bind(id))
		add_child(btn)
		_buttons[id] = btn


func current_tab() -> String:
	return _current_tab


func _on_tab_pressed(tab_id: String) -> void:
	_current_tab = tab_id
	for key in _buttons.keys():
		var btn: Button = _buttons[key]
		btn.set_pressed_no_signal(String(key) == tab_id)
	tab_selected.emit(tab_id)
