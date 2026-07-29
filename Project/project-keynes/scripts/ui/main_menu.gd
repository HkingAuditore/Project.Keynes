extends Control

const PANEL_WIDTH := 520.0
const COMMAND_WIDTH := 300.0
const MAP_PRESETS := [
	{"label": "小型 40 x 28", "size": Vector2i(40, 28)},
	{"label": "标准 60 x 40", "size": Vector2i(60, 40)},
	{"label": "大型 100 x 64", "size": Vector2i(100, 64)},
	{"label": "自定义", "size": Vector2i(60, 40)},
]

var _page_root: Control
var _status_label: Label
var _country_edit: LineEdit
var _foreign_count_box: SpinBox
var _seed_box: SpinBox
var _size_option: OptionButton
var _width_box: SpinBox
var _height_box: SpinBox
var _advanced_controls: Dictionary = {}
var _settings_controls: Dictionary = {}


func _ready() -> void:
	theme = UITokens.make_player_theme()
	set_process(true)
	_build_shell()
	resized.connect(_apply_responsive_layout)
	_show_home()
	_apply_responsive_layout()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var viewport_size := size
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color("101817"))
	var paper := Color("b7aa83", 0.14)
	var ink := Color("223432", 0.72)
	for x in range(-80, int(viewport_size.x) + 120, 86):
		draw_line(Vector2(x, 0), Vector2(x + 170, viewport_size.y), paper, 1.0)
	for y in range(30, int(viewport_size.y), 72):
		draw_line(Vector2(0, y), Vector2(viewport_size.x, y + 36), paper, 1.0)
	var center := Vector2(viewport_size.x * 0.70, viewport_size.y * 0.48)
	for ring in range(1, 7):
		draw_arc(center, ring * 58.0, 0.2, TAU - 0.5, 96, ink, 2.0)
	draw_line(center + Vector2(-360, -70), center + Vector2(330, 115), Color("4b8177", 0.55), 3.0)
	draw_line(center + Vector2(-270, 170), center + Vector2(270, -160), Color("a88b4a", 0.46), 2.0)


func _build_shell() -> void:
	var veil := ColorRect.new()
	veil.color = Color(0.03, 0.055, 0.052, 0.48)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)

	_page_root = MarginContainer.new()
	_page_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_page_root.add_theme_constant_override("margin_left", 56)
	_page_root.add_theme_constant_override("margin_top", 42)
	_page_root.add_theme_constant_override("margin_right", 42)
	_page_root.add_theme_constant_override("margin_bottom", 34)
	add_child(_page_root)

	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_left = 56.0
	_status_label.offset_top = -56.0
	_status_label.offset_right = -42.0
	_status_label.offset_bottom = -22.0
	_status_label.add_theme_color_override("font_color", UITokens.WARN)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_status_label)


func _apply_responsive_layout() -> void:
	if _page_root == null:
		return
	var narrow := size.x < 720.0
	var side_margin := 18 if narrow else 56
	var right_margin := 18 if narrow else 42
	_page_root.add_theme_constant_override("margin_left", side_margin)
	_page_root.add_theme_constant_override("margin_right", right_margin)
	_page_root.add_theme_constant_override("margin_top", 24 if narrow else 42)
	_page_root.add_theme_constant_override("margin_bottom", 66 if narrow else 34)
	_status_label.offset_left = side_margin
	_status_label.offset_right = -right_margin
	var content_width := minf(PANEL_WIDTH, maxf(260.0, size.x - side_margin - right_margin))
	for child in _page_root.get_children():
		if child is Control:
			(child as Control).custom_minimum_size.x = content_width
		if child is ScrollContainer and child.get_child_count() > 0:
			(child.get_child(0) as Control).custom_minimum_size.x = content_width
	for node in get_tree().get_nodes_in_group("main_menu_commands"):
		if is_instance_valid(node) and node is Button:
			(node as Button).custom_minimum_size.x = minf(COMMAND_WIDTH, content_width)


func _clear_page() -> void:
	_status_label.text = ""
	for child in _page_root.get_children():
		child.queue_free()
	call_deferred("_apply_responsive_layout")


func _show_home() -> void:
	_clear_page()
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	layout.add_theme_constant_override("separation", 10)
	_page_root.add_child(layout)

	var title := Label.new()
	title.text = "PROJECT.KEYNES"
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", Color("d9c58c"))
	layout.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "文明、资源与时间的历史模拟"
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color("83aaa0"))
	layout.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size.y = 54.0
	layout.add_child(spacer)
	_add_command(layout, "新游戏", "plus", _show_new_game)
	_add_command(layout, "加载游戏", "history", _show_load_game)
	_add_command(layout, "设置", "settings", _show_settings)
	_add_command(layout, "退出", "close", GameFlow.quit_game)


func _add_command(parent: Control, text: String, icon: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(COMMAND_WIDTH, 50.0)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.add_to_group("main_menu_commands")
	_decorate_text_button(button, text, icon, 18)
	button.pressed.connect(callback)
	parent.add_child(button)


func _show_new_game() -> void:
	_clear_page()
	var panel := _page_panel("建立新的国家", "确定世界的尺度与开端。所有参数都会写入存档。")
	var body := panel.body as VBoxContainer
	_country_edit = LineEdit.new()
	_country_edit.placeholder_text = "国家名称"
	_country_edit.max_length = 32
	_country_edit.text = "新国家"
	body.add_child(_field("国家名称", _country_edit))
	_foreign_count_box = _dimension_box(
		NewGameConfig.MIN_FOREIGN_COUNT,
		NewGameConfig.MAX_FOREIGN_COUNT,
		NewGameConfig.DEFAULT_FOREIGN_COUNT)
	_foreign_count_box.tooltip_text = "生成在玩家国家一定距离之外的其他国家"
	body.add_child(_field("外国数量", _foreign_count_box))

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	_seed_box = SpinBox.new()
	_seed_box.min_value = 1
	_seed_box.max_value = 2147483647
	_seed_box.step = 1
	_seed_box.value = NewGameConfig.random_seed()
	_seed_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_box)
	var random_button := Button.new()
	random_button.tooltip_text = "生成随机地图种子"
	random_button.custom_minimum_size = Vector2(44, 38)
	IconButton.apply(random_button, &"action.refresh", 16, "生成随机地图种子")
	random_button.pressed.connect(func() -> void: _seed_box.value = NewGameConfig.random_seed())
	seed_row.add_child(random_button)
	body.add_child(_field("地图种子", seed_row))

	_size_option = OptionButton.new()
	for preset in MAP_PRESETS:
		_size_option.add_item(String(preset.label))
	_size_option.select(1)
	_size_option.item_selected.connect(_on_size_preset_selected)
	body.add_child(_field("地图尺寸", _size_option))
	var dimensions := HBoxContainer.new()
	dimensions.add_theme_constant_override("separation", 8)
	_width_box = _dimension_box(10, 500, 60)
	_height_box = _dimension_box(8, 400, 40)
	dimensions.add_child(_width_box)
	dimensions.add_child(_height_box)
	body.add_child(_field("自定义宽高", dimensions))
	_set_custom_size_enabled(false)

	var advanced_button := Button.new()
	advanced_button.text = "高级地图设置"
	advanced_button.toggle_mode = true
	advanced_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	advanced_button.custom_minimum_size.y = 38.0
	_decorate_text_button(advanced_button, "高级地图设置", "settings", 15)
	body.add_child(advanced_button)
	var advanced := GridContainer.new()
	advanced.columns = 2
	advanced.visible = false
	advanced.add_theme_constant_override("h_separation", 12)
	advanced.add_theme_constant_override("v_separation", 8)
	body.add_child(advanced)
	advanced_button.toggled.connect(func(open: bool) -> void: advanced.visible = open)
	_add_advanced_spin(advanced, "大陆数量", "num_continents", 1, 8, 2)
	_add_advanced_spin(advanced, "大陆规模", "continent_size", 0.2, 0.9, 0.9, 0.01)
	_add_advanced_spin(advanced, "海平面", "sea_level", 0.1, 0.8, 0.42, 0.01)
	_add_advanced_spin(advanced, "湿润程度", "wetness", 0, 100, 55)
	_add_advanced_spin(advanced, "湖泊密度", "lake_density", 0, 100, 45)
	_add_advanced_spin(advanced, "河流密度", "river_density", 0, 100, 55)
	_add_advanced_spin(advanced, "火山数量", "volcano_amount", 0, 100, 40)

	var actions := _page_actions()
	actions.add_child(_button("返回", "back", _show_home))
	var start := _button("开始游戏", "play", _start_new_game)
	start.add_theme_color_override("font_color", UITokens.ACCENT)
	actions.add_child(start)
	body.add_child(actions)


func _show_load_game() -> void:
	_clear_page()
	var panel := _page_panel("加载游戏", "三个手动槽位与一个自动存档槽位。")
	var body := panel.body as VBoxContainer
	var slots: Array = []
	var save_service := get_node_or_null("/root/GameSave")
	if save_service != null and save_service.has_method("list_slots"):
		slots = save_service.call("list_slots")
	else:
		for slot_id in ["manual_1", "manual_2", "manual_3", "autosave"]:
			slots.append({"slot_id": slot_id, "exists": false, "loadable": false})
	for slot in slots:
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 72.0
		var preview := TextureRect.new()
		preview.custom_minimum_size = Vector2(112, 63)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var description := Label.new()
		description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var slot_id := String(slot.get("slot_id", ""))
		var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
		if bool(slot.get("exists", false)):
			description.text = "%s\n%s · 第 %s 天 · seed %s · %sx%s\n%s" % [label,
				String(slot.get("country_name", "未知国家")), str(slot.get("day", 0)),
				str(slot.get("seed", 0)), str(slot.get("width", 0)), str(slot.get("height", 0)),
				String(slot.get("saved_at", ""))]
			if save_service != null and save_service.has_method("load_preview"):
				var preview_result: Dictionary = save_service.call("load_preview", slot_id)
				if bool(preview_result.get("ok", false)):
					var image := Image.new()
					if image.load_png_from_buffer(preview_result.get(
							"bytes", PackedByteArray())) == OK:
						preview.texture = ImageTexture.create_from_image(image)
		else:
			description.text = "%s\n空槽位" % label
		row.add_child(preview)
		row.add_child(description)
		var load_button := _button("加载", "history", func() -> void: _load_slot(slot_id))
		load_button.disabled = not bool(slot.get("loadable", false))
		if bool(slot.get("exists", false)) and not bool(slot.get("loadable", false)):
			load_button.tooltip_text = String(slot.get("reason", "存档损坏或版本不兼容"))
		row.add_child(load_button)
		body.add_child(row)
	var actions := _page_actions()
	actions.add_child(_button("返回", "back", _show_home))
	body.add_child(actions)


func _show_settings() -> void:
	_clear_page()
	var panel := _page_panel("设置", "显示、界面与声音设置会立即应用。")
	var body := panel.body as VBoxContainer
	var current: Dictionary = GameSettings.values()
	var window_mode := OptionButton.new()
	for item in [{"label": "窗口", "id": "windowed"}, {"label": "无边框", "id": "borderless"}, {"label": "全屏", "id": "fullscreen"}]:
		window_mode.add_item(item.label)
		window_mode.set_item_metadata(window_mode.item_count - 1, item.id)
		if item.id == current.window_mode: window_mode.select(window_mode.item_count - 1)
	_settings_controls.window_mode = window_mode
	body.add_child(_field("窗口模式", window_mode))

	var resolution := OptionButton.new()
	for size_value in [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]:
		resolution.add_item("%d x %d" % [size_value.x, size_value.y])
		resolution.set_item_metadata(resolution.item_count - 1, size_value)
		if size_value == Vector2i(current.resolution_width, current.resolution_height): resolution.select(resolution.item_count - 1)
	_settings_controls.resolution = resolution
	body.add_child(_field("分辨率", resolution))
	_settings_controls.vsync = _check("垂直同步", bool(current.vsync), body)
	_settings_controls.render_quality = _option(["自动", "低", "中", "高"], ["auto", "low", "medium", "high"], String(current.render_quality), "渲染质量", body)
	_settings_controls.ui_scale = _option(["80%", "100%", "125%", "150%"], [80, 100, 125, 150], int(current.ui_scale_percent), "界面缩放", body)
	var volume := HSlider.new()
	volume.min_value = 0
	volume.max_value = 1
	volume.step = 0.01
	volume.value = float(current.master_volume)
	_settings_controls.volume = volume
	body.add_child(_field("主音量", volume))
	_settings_controls.muted = _check("静音", bool(current.master_muted), body)
	var actions := _page_actions()
	actions.add_child(_button("返回", "back", _show_home))
	actions.add_child(_button("应用", "confirm", _apply_settings))
	body.add_child(actions)


func _page_panel(title_text: String, subtitle_text: String) -> Dictionary:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.x = PANEL_WIDTH
	_page_root.add_child(scroll)
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = PANEL_WIDTH
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("d9c58c"))
	body.add_child(title)
	var subtitle := Label.new()
	subtitle.text = subtitle_text
	subtitle.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	body.add_child(subtitle)
	var rule := HSeparator.new()
	body.add_child(rule)
	return {"scroll": scroll, "body": body}


func _field(label_text: String, control: Control) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = label_text
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _dimension_box(minimum: int, maximum: int, value: int) -> SpinBox:
	var box := SpinBox.new()
	box.min_value = minimum
	box.max_value = maximum
	box.step = 1
	box.value = value
	box.rounded = true
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return box


func _add_advanced_spin(grid: GridContainer, label_text: String, key: String,
		minimum: float, maximum: float, value: float, step: float = 1.0) -> void:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var box := SpinBox.new()
	box.min_value = minimum
	box.max_value = maximum
	box.value = value
	box.step = step
	box.rounded = step >= 1.0
	grid.add_child(box)
	_advanced_controls[key] = box


func _page_actions() -> HBoxContainer:
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	actions.custom_minimum_size.y = 58.0
	return actions


func _button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(112, 42)
	_decorate_text_button(button, text_value, icon, 15)
	button.pressed.connect(callback)
	return button


func _decorate_text_button(button: Button, text_value: String, icon: String,
		font_size: int) -> void:
	button.text = ""
	button.tooltip_text = text_value
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)
	var icon_label := Label.new()
	icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	IconButton.apply_to_label(icon_label, StringName(icon), font_size)
	icon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(icon_label)
	var text_label := Label.new()
	text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_label.text = text_value
	text_label.add_theme_font_size_override("font_size", font_size)
	text_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text_label)
	button.add_child(margin)


func _check(text_value: String, value: bool, parent: VBoxContainer) -> CheckBox:
	var check := CheckBox.new()
	check.text = text_value
	check.button_pressed = value
	parent.add_child(check)
	return check


func _option(labels: Array, values: Array, selected, label_text: String,
		parent: VBoxContainer) -> OptionButton:
	var option := OptionButton.new()
	for index in range(labels.size()):
		option.add_item(String(labels[index]))
		option.set_item_metadata(index, values[index])
		if values[index] == selected: option.select(index)
	parent.add_child(_field(label_text, option))
	return option


func _on_size_preset_selected(index: int) -> void:
	var custom := index == MAP_PRESETS.size() - 1
	_set_custom_size_enabled(custom)
	if not custom:
		var map_size: Vector2i = MAP_PRESETS[index].size
		_width_box.value = map_size.x
		_height_box.value = map_size.y


func _set_custom_size_enabled(enabled: bool) -> void:
	_width_box.editable = enabled
	_height_box.editable = enabled


func _start_new_game() -> void:
	var config := NewGameConfig.new()
	config.country.name = _country_edit.text
	config.country.foreign_count = int(_foreign_count_box.value)
	config.base.map_width = int(_width_box.value)
	config.base.map_height = int(_height_box.value)
	config.base.initial_seed = int(_seed_box.value)
	config.base.num_continents = int((_advanced_controls.num_continents as SpinBox).value)
	config.base.continent_size = float((_advanced_controls.continent_size as SpinBox).value)
	config.base.sea_level = float((_advanced_controls.sea_level as SpinBox).value)
	config.world_controls = {
		"wetness": int((_advanced_controls.wetness as SpinBox).value),
		"lake_density": int((_advanced_controls.lake_density as SpinBox).value),
		"river_density": int((_advanced_controls.river_density as SpinBox).value),
		"volcano_amount": int((_advanced_controls.volcano_amount as SpinBox).value),
	}
	var result := GameFlow.begin_new_game(config)
	if not bool(result.get("ok", false)):
		_status_label.text = String(result.get("message", "无法开始新游戏。"))


func _load_slot(slot_id: String) -> void:
	var result := GameFlow.begin_load_game(slot_id)
	if not bool(result.get("ok", false)):
		_status_label.text = String(result.get("message", "无法加载存档。"))


func _apply_settings() -> void:
	var resolution: Vector2i = _settings_controls.resolution.get_selected_metadata()
	var result := GameSettings.update({
		"window_mode": _settings_controls.window_mode.get_selected_metadata(),
		"resolution_width": resolution.x,
		"resolution_height": resolution.y,
		"vsync": _settings_controls.vsync.button_pressed,
		"render_quality": _settings_controls.render_quality.get_selected_metadata(),
		"ui_scale_percent": _settings_controls.ui_scale.get_selected_metadata(),
		"master_volume": _settings_controls.volume.value,
		"master_muted": _settings_controls.muted.button_pressed,
	})
	_status_label.text = "设置已应用。" if bool(result.get("ok", false)) else String(result.message)
