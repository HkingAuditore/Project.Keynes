# map_layer_menu.gd
# 玩家场景左侧两级可展开的数据图层菜单（2026-07-23）。
#
# 第一列（根 VBox）3 个按钮：地理信息 / 气候信息 / 资源信息，各带 FA 图标 + 中文标签。
# 点击根按钮展开其第二列子菜单（同高、根列右侧）。子菜单项点击后
# emit layer_selected(layer_id, display_name) 并自动收起；再次点已激活项或顶部
# 「关闭」项则 emit layer_cleared()。
#
# 子菜单项通过 IconBadge + Label 自绘（FA 图标 + 中文），不依赖 .tscn。

extends Control
class_name MapLayerMenu

signal layer_selected(layer_id: String, display_name: String)
signal layer_cleared()

const DataLayerPalette = preload("res://scripts/rendering/data_layer_palette.gd")
const IconBadge = preload("res://scripts/ui/components/icon_badge.gd")
const ResourceProfileRegistry = preload("res://scripts/data/resource_profile_registry.gd")
const UITokens = preload("res://scripts/ui/ui_tokens.gd")
const PlayerTopBar = preload("res://scripts/ui/components/player_top_bar.gd")

var _root_col: VBoxContainer
var _submenu: Panel
var _submenu_list: VBoxContainer
var _open_category: String = ""
var _active_id: String = ""
var _active_btn: Button = null
var _root_buttons: Dictionary = {}

const _SUBMENU_MAX_H := 380.0
const _BTN_W := 168.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 空白区透传给地图
	_build()

func _build() -> void:
	_root_col = VBoxContainer.new()
	_root_col.name = "LayerRootCol"
	_root_col.position = Vector2(8.0, PlayerTopBar.BAR_HEIGHT + 4.0)
	_root_col.add_theme_constant_override("separation", 4)
	add_child(_root_col)

	_submenu = Panel.new()
	_submenu.name = "LayerSubmenu"
	_submenu.visible = false
	_submenu.mouse_filter = Control.MOUSE_FILTER_STOP
	_submenu.add_theme_stylebox_override("panel",
		UITokens.panel_style(UITokens.CARD_BG, UITokens.RADIUS_MD, UITokens.PANEL_BORDER))
	add_child(_submenu)

	var sc := ScrollContainer.new()
	sc.name = "SubmenuScroll"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_submenu.add_child(sc)

	_submenu_list = VBoxContainer.new()
	_submenu_list.add_theme_constant_override("separation", 2)
	_submenu_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_submenu_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(_submenu_list)

	_add_root_button("geo", "地理信息", "geo")
	_add_root_button("climate", "气候信息", "weather")
	_add_root_button("resource", "资源信息", "gem")

func _add_root_button(category: String, label: String, icon: String) -> void:
	var btn := _make_button(label, icon)
	btn.pressed.connect(func() -> void: _on_root_pressed(category, btn))
	_root_col.add_child(btn)
	_root_buttons[category] = btn

func _on_root_pressed(category: String, btn: Button) -> void:
	if _open_category == category:
		_close_submenu()
		return
	_open_submenu(category, btn)

func _open_submenu(category: String, anchor_btn: Button) -> void:
	_close_submenu()
	_open_category = category
	_build_submenu(category)
	_submenu.visible = true
	var x := _root_col.position.x + _root_col.size.x + 6.0
	var y := _root_col.position.y + anchor_btn.position.y
	_submenu.position = Vector2(x, y)
	_submenu.custom_minimum_size = Vector2(184.0, 0.0)
	# 资源子菜单可能很高 → 限高 + 滚动；并夹住不超出视口底
	var h := _submenu_list.get_combined_minimum_size().y + 16.0
	h = minf(h, _SUBMENU_MAX_H)
	_submenu.custom_minimum_size = Vector2(184.0, h)
	var vh: float = get_viewport().size.y if get_viewport() != null else 720.0
	if y + h > vh - 4.0:
		_submenu.position.y = maxf(4.0, vh - 4.0 - h)

func _close_submenu() -> void:
	_open_category = ""
	_submenu.visible = false
	for c in _submenu_list.get_children().duplicate():
		c.queue_free()

func _build_submenu(category: String) -> void:
	for c in _submenu_list.get_children().duplicate():
		c.queue_free()
	# 顶部「关闭」项
	var close_btn := _make_button("关闭图层", "close")
	close_btn.pressed.connect(func() -> void: _do_clear())
	_submenu_list.add_child(close_btn)

	match category:
		"geo":
			_add_entry("geo.elevation", "海拔", "geo")
			_add_entry("geo.terrain", "地形", "geo")
			_add_entry("geo.vegetation", "植被", "eco")
		"climate":
			_add_entry("climate.temp", "温度", "sun")
			_add_entry("climate.moisture", "湿度", "water")
			_add_entry("climate.wind", "风向", "wind")
			_add_entry("climate.ocean_current", "洋流", "water")
		"resource":
			for p in ResourceProfileRegistry.ordered():
				_add_entry("resource." + String(p.id), String(p.display_name), "gem")

func _add_entry(layer_id: String, label: String, icon: String) -> void:
	var btn := _make_button(label, icon)
	btn.pressed.connect(func() -> void: _on_entry_pressed(layer_id, btn))
	_submenu_list.add_child(btn)

func _on_entry_pressed(layer_id: String, btn: Button) -> void:
	if layer_id == _active_id:
		_do_clear()
		return
	var spec := DataLayerPalette.spec_for(layer_id)
	var disp: String = String(spec.get("display", layer_id)) if not spec.is_empty() else layer_id
	_set_active(layer_id, btn)
	layer_selected.emit(layer_id, disp)
	_close_submenu()

func _do_clear() -> void:
	_active_id = ""
	_clear_active_style()
	layer_cleared.emit()
	_close_submenu()

func _set_active(layer_id: String, btn: Button) -> void:
	_clear_active_style()
	_active_id = layer_id
	_active_btn = btn
	var s := UITokens.button_style(
		Color(0.30, 0.205, 0.105, 0.99), UITokens.BRASS_HIGHLIGHT, UITokens.RADIUS_SM, true)
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("hover", s)
	btn.add_theme_stylebox_override("pressed", s)

func _clear_active_style() -> void:
	if _active_btn != null and is_instance_valid(_active_btn):
		_active_btn.remove_theme_stylebox_override("normal")
		_active_btn.remove_theme_stylebox_override("hover")
		_active_btn.remove_theme_stylebox_override("pressed")
	_active_btn = null

# 自绘按钮：HBox(IconBadge + Label)。子节点 mouse_filter=IGNORE 让点击落到 Button 本身。
func _make_button(label: String, icon: String) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = Vector2(_BTN_W, 30.0)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 6)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var ib := IconBadge.new()
	ib.set_icon(icon)
	ib.custom_minimum_size = Vector2(20.0, 24.0)
	ib.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var lab := Label.new()
	lab.text = label
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	hb.add_child(ib)
	hb.add_child(lab)
	btn.add_child(hb)
	return btn
