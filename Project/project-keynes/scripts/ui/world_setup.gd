extends Control

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://world_setup_settings.json"
const WORLD_SETUP_META := &"world_setup_config"
const MOBILE_LAYOUT_MAX_WIDTH := 900.0
const TOUCH_CONTROL_HEIGHT := 56.0
const TOUCH_BUTTON_HEIGHT := 60.0
const DESKTOP_CONTROL_HEIGHT := 34.0

const PRESETS := [
	{"label": "小 40x28", "width": 40, "height": 28},
	{"label": "当前 60x40", "width": 60, "height": 40},
	{"label": "大 100x64", "width": 100, "height": 64},
	{"label": "自定义", "width": 60, "height": 40},
]

const BASE_FIELDS := [
	{"name": "map_width", "label": "地图宽度", "type": "int", "default": 60, "min": 10, "max": 500, "step": 1},
	{"name": "map_height", "label": "地图高度", "type": "int", "default": 40, "min": 8, "max": 400, "step": 1},
	{"name": "initial_seed", "label": "随机种子", "type": "int", "default": 0, "min": 0, "max": 2147483647, "step": 1},
	{"name": "sea_level", "label": "海平面", "type": "float", "default": 0.42, "min": 0.1, "max": 0.8, "step": 0.01},
	{"name": "num_continents", "label": "大陆数", "type": "int", "default": 2, "min": 1, "max": 8, "step": 1},
	{"name": "river_count", "label": "河流数", "type": "int", "default": 8, "min": 0, "max": 30, "step": 1},
]

const CLIMATE_GROUPS := [
	{
		"title": "大陆形态",
		"fields": [
			{"name": "continent_warp_amp", "label": "大陆扭曲强度", "type": "float", "default": 0.15, "min": 0.0, "max": 0.6, "step": 0.01},
			{"name": "main_radius_min", "label": "主大陆最小半径", "type": "float", "default": 0.70, "min": 0.2, "max": 1.2, "step": 0.01},
			{"name": "main_radius_max", "label": "主大陆最大半径", "type": "float", "default": 0.90, "min": 0.2, "max": 1.2, "step": 0.01},
			{"name": "main_placement_min", "label": "主大陆放置下限", "type": "float", "default": 0.18, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "main_placement_max", "label": "主大陆放置上限", "type": "float", "default": 0.82, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "main_separation_factor", "label": "主大陆间距系数", "type": "float", "default": 0.85, "min": 0.0, "max": 1.5, "step": 0.01},
		],
	},
	{
		"title": "岛屿 / 边缘",
		"fields": [
			{"name": "satellite_radius_min", "label": "卫星岛最小半径", "type": "float", "default": 0.18, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "satellite_radius_max", "label": "卫星岛最大半径", "type": "float", "default": 0.40, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "satellites_per_main", "label": "每大陆卫星岛数", "type": "int", "default": 3, "min": 0, "max": 8, "step": 1},
			{"name": "satellite_placement_min", "label": "卫星岛放置下限", "type": "float", "default": 0.08, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "satellite_placement_max", "label": "卫星岛放置上限", "type": "float", "default": 0.92, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "satellite_separation_factor", "label": "卫星岛间距系数", "type": "float", "default": 0.55, "min": 0.0, "max": 1.5, "step": 0.01},
			{"name": "edge_falloff_start", "label": "边缘衰减起点", "type": "float", "default": 0.80, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "edge_falloff_end", "label": "边缘衰减终点", "type": "float", "default": 0.95, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "edge_falloff_depth", "label": "边缘衰减深度", "type": "float", "default": 0.55, "min": 0.0, "max": 1.0, "step": 0.01},
		],
	},
	{
		"title": "降雨 / 雨影",
		"fields": [
			{"name": "orographic_boost", "label": "地形降雨增强", "type": "float", "default": 1.2, "min": 0.0, "max": 3.0, "step": 0.05},
			{"name": "rain_shadow_threshold", "label": "雨影阈值", "type": "float", "default": 0.13, "min": 0.0, "max": 0.5, "step": 0.01},
			{"name": "rain_shadow_factor", "label": "雨影削减系数", "type": "float", "default": 0.50, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "rain_shadow_lookback", "label": "雨影回看距离", "type": "int", "default": 3, "min": 0, "max": 8, "step": 1},
		],
	},
	{
		"title": "湖泊",
		"fields": [
			{"name": "lake_seed_freq", "label": "湖泊种子噪声频率", "type": "float", "default": 0.18, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "lake_seed_threshold", "label": "湖泊种子阈值", "type": "float", "default": 0.55, "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "lake_seed_depth", "label": "湖泊种子下沉深度", "type": "float", "default": 0.04, "min": 0.0, "max": 0.2, "step": 0.005},
			{"name": "lake_seed_min_interior", "label": "湖泊最小内陆距离", "type": "float", "default": 0.12, "min": 0.0, "max": 0.45, "step": 0.01},
		],
	},
	{
		"title": "火山",
		"fields": [
			{"name": "max_volcanoes", "label": "最大火山数", "type": "int", "default": 8, "min": 0, "max": 32, "step": 1},
			{"name": "volcano_min_dist", "label": "火山最小间距", "type": "int", "default": 6, "min": 0, "max": 20, "step": 1},
			{"name": "volcano_min_land_h", "label": "火山最低陆地高度", "type": "float", "default": 0.65, "min": 0.0, "max": 1.0, "step": 0.01},
		],
	},
	{
		"title": "天气 / 洋流 / 海冰",
		"fields": [
			{"name": "weather_field_enabled", "label": "启用天气场", "type": "bool", "default": true},
			{"name": "physical_circulation_enabled", "label": "启用物理风洋流", "type": "bool", "default": true},
			{"name": "sea_ice_independent_system_enabled", "label": "启用独立海冰刷新", "type": "bool", "default": true},
			{"name": "sea_ice_form_threshold", "label": "海冰形成温度阈值", "type": "float", "default": 0.14, "min": -1.0, "max": 1.0, "step": 0.01},
			{"name": "sea_ice_melt_threshold", "label": "海冰融化温度阈值", "type": "float", "default": 0.22, "min": -1.0, "max": 1.0, "step": 0.01},
		],
	},
	{
		"title": "运行时实验",
		"fields": [
			{"name": "fast_slow_layering_enabled", "label": "启用快慢层分离", "type": "bool", "default": true},
			{"name": "use_climate_round_async", "label": "异步气候轮次", "type": "bool", "default": true},
		],
	},
]

var _preset_option: OptionButton
var _cell_count_label: Label
var _base_controls: Dictionary = {}
var _climate_controls: Dictionary = {}
var _syncing := false
var _mobile_layout := false


func _ready() -> void:
	_build_ui()
	_apply_default_values()
	_load_settings()
	_update_cell_count()


func _is_mobile_layout() -> bool:
	return OS.has_feature("mobile") or get_viewport_rect().size.x <= MOBILE_LAYOUT_MAX_WIDTH


func _button_min_size(base_width: float) -> Vector2:
	if _mobile_layout:
		return Vector2(base_width, TOUCH_BUTTON_HEIGHT)
	return Vector2(base_width, DESKTOP_CONTROL_HEIGHT)


func _button_h_size_flags() -> int:
	if _mobile_layout:
		return Control.SIZE_EXPAND_FILL
	return Control.SIZE_SHRINK_CENTER


func _control_min_size(base_width: float, desktop_height: float) -> Vector2:
	if _mobile_layout:
		return Vector2(base_width, TOUCH_CONTROL_HEIGHT)
	return Vector2(base_width, desktop_height)


func _build_ui() -> void:
	_mobile_layout = _is_mobile_layout()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var outer_margin: int = 18
	if _mobile_layout:
		outer_margin = 10
	margin.add_theme_constant_override("margin_left", outer_margin)
	margin.add_theme_constant_override("margin_top", outer_margin)
	margin.add_theme_constant_override("margin_right", outer_margin)
	margin.add_theme_constant_override("margin_bottom", outer_margin)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12 if _mobile_layout else 10)
	margin.add_child(root)

	var header: BoxContainer = VBoxContainer.new()
	if not _mobile_layout:
		header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)

	var title := Label.new()
	title.text = "World Setup"
	title.add_theme_font_size_override("font_size", 30 if _mobile_layout else 28)
	header.add_child(title)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	if _mobile_layout:
		header.add_child(actions)
	else:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(spacer)
		header.add_child(actions)

	var reset_btn := Button.new()
	reset_btn.text = "恢复默认"
	reset_btn.custom_minimum_size = _button_min_size(96.0)
	reset_btn.size_flags_horizontal = _button_h_size_flags()
	reset_btn.pressed.connect(_on_reset_pressed)
	actions.add_child(reset_btn)

	var start_btn := Button.new()
	start_btn.text = "生成世界"
	start_btn.custom_minimum_size = _button_min_size(120.0)
	start_btn.size_flags_horizontal = _button_h_size_flags()
	start_btn.pressed.connect(_on_start_pressed)
	actions.add_child(start_btn)

	if _mobile_layout:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(scroll)

		var content := VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_theme_constant_override("separation", 14)
		scroll.add_child(content)

		_build_base_panel(content)
		_build_climate_panel(content)
	else:
		var body := HSplitContainer.new()
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(body)

		var left_panel := VBoxContainer.new()
		left_panel.custom_minimum_size = Vector2(360, 0)
		left_panel.add_theme_constant_override("separation", 8)
		body.add_child(left_panel)

		var advanced_scroll := ScrollContainer.new()
		advanced_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		advanced_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		advanced_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body.add_child(advanced_scroll)

		var advanced := VBoxContainer.new()
		advanced.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		advanced.add_theme_constant_override("separation", 8)
		advanced_scroll.add_child(advanced)

		_build_base_panel(left_panel)
		_build_climate_panel(advanced)


func _build_base_panel(parent: VBoxContainer) -> void:
	var base_title := Label.new()
	base_title.text = "基础参数"
	base_title.add_theme_font_size_override("font_size", 24 if _mobile_layout else 20)
	parent.add_child(base_title)

	_preset_option = OptionButton.new()
	_preset_option.custom_minimum_size = _control_min_size(0.0, DESKTOP_CONTROL_HEIGHT)
	for preset in PRESETS:
		_preset_option.add_item(String(preset["label"]))
	_preset_option.item_selected.connect(_on_preset_selected)
	parent.add_child(_row_with_label("地图预设", _preset_option))

	for field in BASE_FIELDS:
		var control := _create_field_control(field)
		_base_controls[String(field["name"])] = control
		parent.add_child(_row_with_label(String(field["label"]), control))

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	var random_seed_btn := Button.new()
	random_seed_btn.text = "随机 seed"
	random_seed_btn.custom_minimum_size = _button_min_size(96.0)
	random_seed_btn.size_flags_horizontal = _button_h_size_flags()
	random_seed_btn.pressed.connect(_on_random_seed_pressed)
	seed_row.add_child(random_seed_btn)
	parent.add_child(seed_row)

	_cell_count_label = Label.new()
	_cell_count_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_cell_count_label)


func _build_climate_panel(parent: VBoxContainer) -> void:
	var advanced_title := Label.new()
	advanced_title.text = "高级生成参数"
	advanced_title.add_theme_font_size_override("font_size", 24 if _mobile_layout else 20)
	parent.add_child(advanced_title)

	for group in CLIMATE_GROUPS:
		var section := _create_foldout(String(group["title"]))
		parent.add_child(section["root"])
		var body := section["body"] as VBoxContainer
		for field in group["fields"]:
			var control := _create_field_control(field)
			_climate_controls[String(field["name"])] = control
			body.add_child(_row_with_label(String(field["label"]), control))


func _create_foldout(title: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header := Button.new()
	header.text = "v  " + title
	header.toggle_mode = true
	header.button_pressed = true
	header.custom_minimum_size = _button_min_size(0.0)
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	root.add_child(header)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	root.add_child(body)
	header.toggled.connect(func(pressed: bool) -> void:
		body.visible = pressed
		header.text = ("v  " if pressed else ">  ") + title
	)
	return {"root": root, "body": body}


func _row_with_label(label_text: String, control: Control) -> BoxContainer:
	var row: BoxContainer = VBoxContainer.new()
	if not _mobile_layout:
		row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var separation: int = 10
	if _mobile_layout:
		separation = 6
	row.add_theme_constant_override("separation", separation)
	var label := Label.new()
	label.text = label_text
	var label_width := 180.0
	if _mobile_layout:
		label_width = 0.0
	label.custom_minimum_size = Vector2(label_width, 0.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not _mobile_layout:
		label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _mobile_layout:
		label.add_theme_font_size_override("font_size", 18)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _create_field_control(field: Dictionary) -> Control:
	var field_type := String(field["type"])
	if field_type == "bool":
		var check := CheckBox.new()
		check.text = "启用"
		check.button_pressed = bool(field.get("default", false))
		check.custom_minimum_size = _control_min_size(0.0, DESKTOP_CONTROL_HEIGHT)
		check.toggled.connect(func(_pressed: bool) -> void: _on_field_changed())
		return check

	var spin := SpinBox.new()
	spin.min_value = float(field.get("min", 0.0))
	spin.max_value = float(field.get("max", 1.0))
	spin.step = float(field.get("step", 0.01))
	spin.value = float(field.get("default", 0.0))
	spin.rounded = field_type == "int"
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.select_all_on_focus = true
	spin.custom_minimum_size = _control_min_size(120.0, 32.0)
	spin.value_changed.connect(func(_value: float) -> void: _on_number_field_changed())
	return spin


func _apply_default_values() -> void:
	_syncing = true
	_preset_option.select(1)
	for field in BASE_FIELDS:
		_set_control_value(_base_controls[String(field["name"])], field.get("default"))
	for group in CLIMATE_GROUPS:
		for field in group["fields"]:
			_set_control_value(_climate_controls[String(field["name"])], field.get("default"))
	_syncing = false
	_enforce_range_pairs()


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_apply_config(parsed as Dictionary)


func _apply_config(config: Dictionary) -> void:
	_syncing = true
	var base = config.get("base", {})
	if base is Dictionary:
		for field in BASE_FIELDS:
			var name := String(field["name"])
			if (base as Dictionary).has(name):
				_set_control_value(_base_controls[name], (base as Dictionary)[name])
	var climate = config.get("climate", {})
	if climate is Dictionary:
		for group in CLIMATE_GROUPS:
			for field in group["fields"]:
				var name := String(field["name"])
				if (climate as Dictionary).has(name):
					_set_control_value(_climate_controls[name], (climate as Dictionary)[name])
	_syncing = false
	_enforce_range_pairs()
	_update_preset_from_size()
	_update_cell_count()


func _set_control_value(control: Control, value) -> void:
	if control is SpinBox:
		(control as SpinBox).value = float(value)
	elif control is CheckBox:
		(control as CheckBox).button_pressed = bool(value)


func _control_value(control: Control, field_type: String):
	if control is SpinBox:
		var v := (control as SpinBox).value
		return int(round(v)) if field_type == "int" else float(v)
	if control is CheckBox:
		return (control as CheckBox).button_pressed
	return null


func _on_preset_selected(index: int) -> void:
	if _syncing or index < 0 or index >= PRESETS.size() - 1:
		return
	_syncing = true
	var preset := PRESETS[index] as Dictionary
	_set_control_value(_base_controls["map_width"], preset["width"])
	_set_control_value(_base_controls["map_height"], preset["height"])
	_syncing = false
	_update_cell_count()


func _on_number_field_changed() -> void:
	if _syncing:
		return
	_enforce_range_pairs()
	_update_preset_from_size()
	_update_cell_count()


func _on_field_changed() -> void:
	if _syncing:
		return
	_enforce_range_pairs()
	_update_cell_count()


func _on_random_seed_pressed() -> void:
	_set_control_value(_base_controls["initial_seed"], 0)


func _on_reset_pressed() -> void:
	_apply_default_values()
	_update_cell_count()
	_save_settings()


func _on_start_pressed() -> void:
	var config := _build_config()
	Engine.set_meta(WORLD_SETUP_META, config)
	_save_settings(config)
	get_tree().change_scene_to_file(MAIN_SCENE_PATH)


func _build_config() -> Dictionary:
	var base := {}
	for field in BASE_FIELDS:
		var name := String(field["name"])
		base[name] = _control_value(_base_controls[name], String(field["type"]))

	var climate := {}
	for group in CLIMATE_GROUPS:
		for field in group["fields"]:
			var name := String(field["name"])
			climate[name] = _control_value(_climate_controls[name], String(field["type"]))

	return {
		"version": 1,
		"source": "world_setup",
		"base": base,
		"climate": climate,
	}


func _save_settings(config: Dictionary = {}) -> void:
	var data: Dictionary = config
	if data.is_empty():
		data = _build_config()
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))


func _enforce_range_pairs() -> void:
	_syncing = true
	_enforce_pair(_climate_controls, "main_radius_min", "main_radius_max")
	_enforce_pair(_climate_controls, "main_placement_min", "main_placement_max")
	_enforce_pair(_climate_controls, "satellite_radius_min", "satellite_radius_max")
	_enforce_pair(_climate_controls, "satellite_placement_min", "satellite_placement_max")
	_enforce_pair(_climate_controls, "edge_falloff_start", "edge_falloff_end")
	_syncing = false


func _enforce_pair(controls: Dictionary, min_name: String, max_name: String) -> void:
	var min_box := controls.get(min_name) as SpinBox
	var max_box := controls.get(max_name) as SpinBox
	if min_box == null or max_box == null:
		return
	if min_box.value > max_box.value:
		max_box.value = min_box.value


func _update_preset_from_size() -> void:
	if _syncing:
		return
	var w := int(round((_base_controls["map_width"] as SpinBox).value))
	var h := int(round((_base_controls["map_height"] as SpinBox).value))
	for i in range(PRESETS.size() - 1):
		var preset := PRESETS[i] as Dictionary
		if int(preset["width"]) == w and int(preset["height"]) == h:
			_preset_option.select(i)
			return
	_preset_option.select(PRESETS.size() - 1)


func _update_cell_count() -> void:
	if _cell_count_label == null:
		return
	var w := int(round((_base_controls["map_width"] as SpinBox).value))
	var h := int(round((_base_controls["map_height"] as SpinBox).value))
	_cell_count_label.text = "预计地块：%d x %d = %d。seed=0 表示每次随机。" % [w, h, w * h]
