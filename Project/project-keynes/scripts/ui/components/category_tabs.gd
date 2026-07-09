extends VBoxContainer
class_name CategoryTabs

signal tab_selected(tab_id: String)

var _current_tab: String = ""
var _buttons: Dictionary = {}


func set_tabs(tabs: Array, current_tab: String = "") -> void:
	for child in get_children():
		child.queue_free()
	_buttons.clear()
	custom_minimum_size = Vector2(58.0, 0.0)
	add_theme_constant_override("separation", 10)
	if tabs.is_empty():
		return
	_current_tab = current_tab if current_tab != "" else String(tabs[0].get("id", ""))
	for tab in tabs:
		var data: Dictionary = tab
		var id := String(data.get("id", ""))
		var label := String(data.get("label", id))
		var icon_key := IconBadge.normalize_icon(String(data.get("icon", id)))
		var btn := Button.new()
		btn.text = IconBadge.glyph_for_key(icon_key)
		btn.tooltip_text = label
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.custom_minimum_size = Vector2(52.0, 48.0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_override("font", IconBadge.FA_SOLID_FONT)
		btn.add_theme_font_size_override("font_size", 19)
		btn.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.94, 0.74, 1.0))
		btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.86, 0.48, 1.0))
		btn.add_theme_stylebox_override("normal", UITokens.button_style(Color(0.080, 0.060, 0.040, 0.96), Color(0.42, 0.31, 0.17, 0.70), UITokens.RADIUS_MD))
		btn.add_theme_stylebox_override("hover", UITokens.button_style(Color(0.135, 0.094, 0.052, 0.98), Color(0.82, 0.62, 0.32, 0.92), UITokens.RADIUS_MD))
		btn.add_theme_stylebox_override("pressed", UITokens.button_style(Color(0.255, 0.175, 0.085, 0.98), Color(1.00, 0.76, 0.36, 0.98), UITokens.RADIUS_MD))
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
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
