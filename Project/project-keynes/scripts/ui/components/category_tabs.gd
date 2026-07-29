extends HBoxContainer
class_name CategoryTabs

signal tab_selected(tab_id: String)

var _current_tab: String = ""
var _buttons: Dictionary = {}


func set_tabs(tabs: Array, current_tab: String = "", show_labels: bool = false) -> void:
	clear_tabs()
	custom_minimum_size = Vector2(0.0, 36.0)
	add_theme_constant_override("separation", 2)
	if tabs.is_empty():
		return
	_current_tab = current_tab if current_tab != "" else String(tabs[0].get("id", ""))
	for tab in tabs:
		var data: Dictionary = tab
		var id := String(data.get("id", ""))
		var label := String(data.get("label", id))
		var icon_key := IconBadge.normalize_icon(String(data.get("icon", id)))
		var btn := Button.new()
		btn.text = label if show_labels else ""
		btn.tooltip_text = String(data.get("tooltip", label))
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.custom_minimum_size = Vector2(0.0, 34.0) if show_labels else Vector2(54.0, 34.0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		btn.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.94, 0.74, 1.0))
		btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.86, 0.48, 1.0))
		var icon_margin := 28.0 if show_labels else 6.0
		btn.add_theme_stylebox_override("normal", _tab_style(Color(0.035, 0.033, 0.029, 0.56), UITokens.PANEL_BORDER_SOFT, 1, icon_margin))
		btn.add_theme_stylebox_override("hover", _tab_style(UITokens.WALNUT, UITokens.PANEL_BORDER, 2, icon_margin))
		btn.add_theme_stylebox_override("pressed", _tab_style(Color(0.18, 0.125, 0.065, 0.98), UITokens.BRASS_HIGHLIGHT, 3, icon_margin))
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var icon := IconBadge.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.custom_minimum_size = Vector2(20.0, 20.0)
		if show_labels:
			icon.anchor_top = 0.5
			icon.anchor_bottom = 0.5
			icon.offset_left = 7.0
			icon.offset_right = 27.0
			icon.offset_top = -10.0
			icon.offset_bottom = 10.0
			btn.add_child(icon)
		else:
			var center := CenterContainer.new()
			center.mouse_filter = Control.MOUSE_FILTER_IGNORE
			center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			btn.add_child(center)
			center.add_child(icon)
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


func _tab_style(bg: Color, edge: Color, bottom_width: int,
		left_margin: float = 6.0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = edge
	style.border_width_bottom = bottom_width
	style.corner_radius_top_left = UITokens.RADIUS_SM
	style.corner_radius_top_right = UITokens.RADIUS_SM
	style.content_margin_left = left_margin
	style.content_margin_right = 6
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	style.anti_aliasing = true
	return style
