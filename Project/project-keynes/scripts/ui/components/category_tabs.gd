extends HBoxContainer
class_name CategoryTabs

const TabButtonScene := preload("res://scenes/ui/category_tab_button.tscn")
const TouchUI := preload("res://scripts/ui/touch_ui.gd")

signal tab_selected(tab_id: String)

## 触摸档下纸签**本体**的目标高度（dp）。命中区目标（44dp）减去这些再靠
## touch_hit_button 的上下扩展补齐：视觉只从 34 长到 56 设计像素，
## 可点区域却有 88（= 44dp @440dpi）。
const TOUCH_TAB_VISUAL_DP := 28.0
## 触摸档下页签之间的缝（dp），避免手指同时压住两个页签。
const TOUCH_TAB_GAP_DP := 4.0
## 触摸档下页签图标的边长（dp）。原设计 20 设计像素 = 10dp，放大后仍偏小。
const TOUCH_TAB_ICON_DP := 14.0

var _current_tab: String = ""
var _buttons: Dictionary = {}
var _tab_accents: Dictionary = {}


func _ready() -> void:
	_apply_touch_layout()


func set_tabs(tabs: Array, current_tab: String = "", show_labels: bool = false) -> void:
	clear_tabs()
	if tabs.is_empty():
		return
	_apply_touch_layout()
	var band := TouchUI.min_units()
	var visual := maxf(34.0, TouchUI.units(TOUCH_TAB_VISUAL_DP))
	var icon_size := maxf(20.0, TouchUI.units(TOUCH_TAB_ICON_DP))
	_current_tab = current_tab if current_tab != "" else String(tabs[0].get("id", ""))
	for tab in tabs:
		var data: Dictionary = tab
		var id := String(data.get("id", ""))
		var label := String(data.get("label", id))
		var icon_key := IconBadge.normalize_icon(String(data.get("icon", id)))
		var accent: Color = data.get("accent", UITokens.ACCENT)
		_tab_accents[id] = accent
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
			btn.custom_minimum_size = Vector2(0.0, 36.0)
			btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			icon_center.anchor_right = 0.0
			icon_center.offset_left = 6.0
			icon_center.offset_right = 30.0
		if band > 0.0:
			# 触摸档：本体保持较矮的纸签，整条页签栏给足 44dp 的命中带，
			# 靠 _has_point 把纸签上下各扩 (band - visual) / 2。
			btn.custom_minimum_size.y = visual
			btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			if btn.has_method("set_touch_padding"):
				btn.call("set_touch_padding",
					Vector2(0.0, maxf(0.0, (band - visual) * 0.5)))
			icon.custom_minimum_size = Vector2(icon_size, icon_size)
			if show_labels:
				icon_center.offset_left = 8.0
				icon_center.offset_right = 8.0 + icon_size
		icon.set_semantic(StringName(icon_key), accent)
		btn.set_pressed_no_signal(id == _current_tab)
		btn.pressed.connect(_on_tab_pressed.bind(id))
		add_child(btn)
		_buttons[id] = btn
	_refresh_tab_accents()


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
	_refresh_tab_accents()


func clear_tabs() -> void:
	# queue_free 要到帧末才离树。同一帧里再 set_tabs 会让旧按钮继续参与
	# HBox 最小宽度，页签叠几份后把右侧档案面板撑歪。
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_buttons.clear()
	_tab_accents.clear()
	_current_tab = ""


func _get_minimum_size() -> Vector2:
	# 页签只占用父级给的宽度，不要用子按钮合计最小宽去撑开档案面板。
	var floor_height := maxf(custom_minimum_size.y, TouchUI.min_units())
	return Vector2(0.0, maxf(floor_height, 36.0))


## 触摸档：整条栏抬到命中区高度，页签之间留出缝；桌面档这两项都不动。
func _apply_touch_layout() -> void:
	var band := TouchUI.min_units()
	if band <= 0.0:
		return
	custom_minimum_size.y = maxf(custom_minimum_size.y, band)
	add_theme_constant_override("separation",
		maxi(get_theme_constant("separation"),
			int(ceilf(TouchUI.units(TOUCH_TAB_GAP_DP)))))


func _refresh_tab_accents() -> void:
	for key in _buttons.keys():
		var button := _buttons[key] as Button
		if button == null:
			continue
		var icon := button.get_node_or_null("IconCenter/Icon") as IconBadge
		if icon == null:
			continue
		var accent: Color = _tab_accents.get(key, UITokens.ACCENT)
		if String(key) != _current_tab:
			accent = accent.lerp(UITokens.TEXT_FAINT, 0.45)
		icon.accent = accent
		icon.queue_redraw()


func _on_tab_pressed(tab_id: String) -> void:
	select_tab(tab_id)
	tab_selected.emit(tab_id)
