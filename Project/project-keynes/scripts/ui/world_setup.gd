extends Control

const SectionTitleScene := preload("res://scenes/ui/setup_section_title.tscn")
const SetupOptionScene := preload("res://scenes/ui/setup_option.tscn")
const SetupBoolScene := preload("res://scenes/ui/setup_bool.tscn")
const SetupSpinScene := preload("res://scenes/ui/setup_spin.tscn")
const SetupSliderSpinScene := preload("res://scenes/ui/setup_slider_spin.tscn")
const SetupFoldoutScene := preload("res://scenes/ui/setup_foldout.tscn")
const SetupSeedActionsScene := preload("res://scenes/ui/setup_seed_actions.tscn")
const SetupCellCountScene := preload("res://scenes/ui/setup_cell_count.tscn")

const MAIN_SCENE_PATH := "res://scenes/player_game.tscn"
const DEBUG_SCENE_PATH := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://world_setup_settings.json"
const WORLD_SETUP_META := &"world_setup_config"
const SetupFieldRowScene := preload("res://scenes/ui/setup_field_row.tscn")
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
	{"name": "map_width", "label": "地图宽度", "hint": "调大：地块更多、生成更慢", "type": "int", "default": 60, "min": 10, "max": 500, "step": 1},
	{"name": "map_height", "label": "地图高度", "hint": "调大：南北更宽、地块更多", "type": "int", "default": 40, "min": 8, "max": 400, "step": 1},
	{"name": "initial_seed", "label": "随机种子", "hint": "0=每次随机；同一个数字生成同一张图", "type": "int", "default": 0, "min": 0, "max": 2147483647, "step": 1},
	{"name": "sea_level", "label": "海洋多少", "hint": "调大：海洋更多、陆地更少", "type": "float", "default": 0.42, "min": 0.1, "max": 0.8, "step": 0.01},
	{"name": "num_continents", "label": "大陆块数", "hint": "调大：大陆核心更多、更分散", "type": "int", "default": 2, "min": 1, "max": 8, "step": 1},
	{"name": "continent_size", "label": "大陆整体大小", "hint": "调大：每块大陆更大、更容易连成片", "type": "float", "default": 0.9, "min": 0.2, "max": 0.9, "step": 0.01},
	{"name": "generate_test_economy_data", "label": "生成测试经济数据", "hint": "仅用于开发测试：按石器时代科技与可见资源生成临时人口和建筑，市场库存从零开始。", "type": "bool", "default": false},
	{
		"name": "test_economy_population_scale",
		"label": "测试人口规模",
		"hint": "混合模式按当地资源承载力，让同一世界同时出现十人、百人、千人、万人级聚落。",
		"type": "option",
		"default": 0,
		"options": [
			{"label": "资源分层混合（推荐）", "value": 0},
			{"label": "产能基线（约数十人）", "value": 1},
			{"label": "百人级（10 倍）", "value": 10},
			{"label": "千人级（100 倍）", "value": 100},
			{"label": "万人级（1000 倍）", "value": 1000},
		],
	},
]

const CLIMATE_GROUPS := [
	{
		"title": "陆地形状",
		"fields": [
			{"name": "continent_spacing", "label": "大陆分散度", "hint": "调大：大陆之间更分开；调小：更容易连成一片", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
			{"name": "island_amount", "label": "岛屿数量", "hint": "调大：岛屿和群岛更多；调小：海面更干净", "type": "int", "default": 50, "min": 0, "max": 100, "step": 1},
			{"name": "coast_roughness", "label": "海岸曲折度", "hint": "调大：海岸线更碎、更曲折；调小：大陆边缘更圆滑", "type": "int", "default": 50, "min": 0, "max": 100, "step": 1},
		],
	},
	{
		"title": "山脉与地形",
		"fields": [
			{"name": "relief_amount", "label": "地形起伏", "hint": "调大：高地/盆地更明显，河流流域更大；调小：更平坦", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
			{"name": "mountain_amount", "label": "山脉强度", "hint": "调大：山更高更连片；调小：山脉更弱", "type": "int", "default": 60, "min": 0, "max": 100, "step": 1},
			{"name": "valley_amount", "label": "河谷切割", "hint": "调大：河谷更深、河道更清晰；调小：侵蚀更弱", "type": "int", "default": 45, "min": 0, "max": 100, "step": 1},
		],
	},
	{
		"title": "湿润程度",
		"fields": [
			{"name": "wetness", "label": "整体湿润", "hint": "调大：森林/沼泽/湿润地更多；调小：草原/荒漠更多", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
			{"name": "coastal_wetness", "label": "沿海湿润带", "hint": "调大：海边更湿、湿润带更宽；调小：海岸影响更弱", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
			{"name": "rain_shadow", "label": "山脉挡雨", "hint": "调大：背风侧更容易变干；调小：雨影更弱", "type": "int", "default": 50, "min": 0, "max": 100, "step": 1},
		],
	},
	{
		"title": "湖泊",
		"fields": [
			{"name": "lake_density", "label": "湖泊密度", "hint": "调大：湖泊更多；调小：湖泊更少", "type": "int", "default": 45, "min": 0, "max": 100, "step": 1},
			{"name": "lake_size", "label": "湖泊大小", "hint": "调大：单个湖更大更深；调小：湖更小", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
		],
	},
	{
		"title": "河流",
		"fields": [
			{"name": "river_density", "label": "河流密度", "hint": "调大：支流更多、水网更密；调小：只保留大河", "type": "int", "default": 55, "min": 0, "max": 100, "step": 1},
			{"name": "short_rivers", "label": "短河保留", "hint": "调大：中短河也会显示；调小：只显示长河", "type": "int", "default": 50, "min": 0, "max": 100, "step": 1},
		],
	},
	{
		"title": "特殊地貌",
		"fields": [
			{"name": "volcano_amount", "label": "火山数量", "hint": "调大：火山更多、间距更近；调小：火山更少", "type": "int", "default": 40, "min": 0, "max": 100, "step": 1},
		],
	},
]

var _preset_option: OptionButton
var _cell_count_label: Label
var _base_controls: Dictionary = {}
var _render_controls: Dictionary = {}
var _climate_controls: Dictionary = {}
var _syncing := false
var _mobile_layout := false

const RENDER_FIELDS := [
	{
		"name": "render_quality_mode",
		"label": "渲染质量",
		"hint": "自动：沿用平台默认；低/中/高会手动指定 visual quality，移动端也同步指定 shader quality tier。",
		"type": "option",
		"default": -1,
		"options": [
			{"label": "自动", "value": -1},
			{"label": "低", "value": 0},
			{"label": "中", "value": 1},
			{"label": "高", "value": 2},
		],
	},
	{
		"name": "mobile_terrain_horizon_enabled",
		"label": "移动端地形阴影",
		"hint": "移动端默认关闭；开启后会启用 terrain horizon 烘焙和高质量 shader，画面更有地形投影但更耗 GPU。",
		"type": "bool",
		"default": false,
	},
]


func _ready() -> void:
	_build_ui()
	_apply_default_values()
	_load_settings()
	_update_cell_count()
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()


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
	var margin := %Margin as MarginContainer
	var outer_margin: int = 18
	if _mobile_layout:
		outer_margin = 10
	margin.add_theme_constant_override("margin_left", outer_margin)
	margin.add_theme_constant_override("margin_top", outer_margin)
	margin.add_theme_constant_override("margin_right", outer_margin)
	margin.add_theme_constant_override("margin_bottom", outer_margin)
	var root := %Root as VBoxContainer
	root.add_theme_constant_override("separation", 12 if _mobile_layout else 10)
	var header := %Header as BoxContainer
	header.vertical = _mobile_layout
	header.add_theme_constant_override("separation", 12)
	var title := %Title as Label
	title.add_theme_font_size_override("font_size", 30 if _mobile_layout else 28)
	var actions := %Actions as HBoxContainer
	actions.add_theme_constant_override("separation", 10)
	%HeaderSpacer.visible = not _mobile_layout
	var reset_btn := %ResetButton as Button
	reset_btn.custom_minimum_size = _button_min_size(96.0)
	reset_btn.size_flags_horizontal = _button_h_size_flags()
	reset_btn.pressed.connect(_on_reset_pressed)
	var start_btn := %StartButton as Button
	start_btn.custom_minimum_size = _button_min_size(120.0)
	start_btn.size_flags_horizontal = _button_h_size_flags()
	start_btn.pressed.connect(_on_start_pressed)
	var debug_btn := %DebugButton as Button
	debug_btn.custom_minimum_size = _button_min_size(120.0)
	debug_btn.size_flags_horizontal = _button_h_size_flags()
	debug_btn.pressed.connect(_on_debug_pressed)
	var body := %ResponsiveBody as BoxContainer
	body.vertical = _mobile_layout
	_build_base_panel(%BaseSettings)
	_build_render_panel(%BaseSettings)
	_build_climate_panel(%ClimateSettings)


func _apply_responsive_layout() -> void:
	var mobile := _is_mobile_layout()
	_mobile_layout = mobile
	(%Header as BoxContainer).vertical = mobile
	(%ResponsiveBody as BoxContainer).vertical = mobile
	%HeaderSpacer.visible = not mobile
	var outer_margin := 10 if mobile else 18
	for side in ["left", "top", "right", "bottom"]:
		(%Margin as MarginContainer).add_theme_constant_override(
			"margin_%s" % side, outer_margin)
	for button in [%ResetButton, %StartButton, %DebugButton]:
		button.custom_minimum_size.y = TOUCH_BUTTON_HEIGHT if mobile else DESKTOP_CONTROL_HEIGHT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL if mobile else Control.SIZE_SHRINK_CENTER
	for row in get_tree().get_nodes_in_group("world_setup_field_rows"):
		if row is SetupFieldRow and is_ancestor_of(row):
			row.set_mobile_layout(mobile)


func _build_base_panel(parent: VBoxContainer) -> void:
	var base_title := SectionTitleScene.instantiate() as Label
	base_title.text = "基础参数"
	base_title.add_theme_font_size_override("font_size", 24 if _mobile_layout else 20)
	parent.add_child(base_title)

	_preset_option = SetupOptionScene.instantiate() as OptionButton
	_preset_option.custom_minimum_size = _control_min_size(0.0, DESKTOP_CONTROL_HEIGHT)
	for preset in PRESETS:
		_preset_option.add_item(String(preset["label"]))
	_preset_option.item_selected.connect(_on_preset_selected)
	parent.add_child(_row_with_label("地图预设", _preset_option))

	for field in BASE_FIELDS:
		var control := _create_field_control(field)
		_base_controls[String(field["name"])] = control
		parent.add_child(_row_with_label(String(field["label"]), control, String(field.get("hint", ""))))

	var seed_row := SetupSeedActionsScene.instantiate() as HBoxContainer
	var random_seed_btn := seed_row.get_node("RandomSeedButton") as Button
	random_seed_btn.custom_minimum_size = _button_min_size(96.0)
	random_seed_btn.size_flags_horizontal = _button_h_size_flags()
	random_seed_btn.pressed.connect(_on_random_seed_pressed)
	parent.add_child(seed_row)

	_cell_count_label = SetupCellCountScene.instantiate() as Label
	parent.add_child(_cell_count_label)


func _build_render_panel(parent: VBoxContainer) -> void:
	var render_title := SectionTitleScene.instantiate() as Label
	render_title.text = "渲染选项"
	render_title.add_theme_font_size_override("font_size", 24 if _mobile_layout else 20)
	parent.add_child(render_title)

	for field in RENDER_FIELDS:
		var control := _create_field_control(field)
		_render_controls[String(field["name"])] = control
		parent.add_child(_row_with_label(String(field["label"]), control, String(field.get("hint", ""))))


func _build_climate_panel(parent: VBoxContainer) -> void:
	var advanced_title := SectionTitleScene.instantiate() as Label
	advanced_title.text = "世界风格（简单调节）"
	advanced_title.add_theme_font_size_override("font_size", 24 if _mobile_layout else 20)
	parent.add_child(advanced_title)

	for group in CLIMATE_GROUPS:
		var section := _create_foldout(String(group["title"]))
		parent.add_child(section["root"])
		var body := section["body"] as VBoxContainer
		for field in group["fields"]:
			var control := _create_field_control(field)
			_climate_controls[String(field["name"])] = control
			body.add_child(_row_with_label(String(field["label"]), control, String(field.get("hint", ""))))


func _create_foldout(title: String) -> Dictionary:
	var root := SetupFoldoutScene.instantiate() as VBoxContainer
	var header := root.get_node("Header") as Button
	header.text = "v  " + title
	header.custom_minimum_size = _button_min_size(0.0)
	var body := root.get_node("Body") as VBoxContainer
	header.toggled.connect(func(pressed: bool) -> void:
		body.visible = pressed
		header.text = ("v  " if pressed else ">  ") + title
	)
	return {"root": root, "body": body}


func _row_with_label(label_text: String, control: Control, hint_text: String = "") -> BoxContainer:
	var row := SetupFieldRowScene.instantiate() as SetupFieldRow
	row.configure(label_text, hint_text, control, _mobile_layout)
	return row


func _create_field_control(field: Dictionary) -> Control:
	var field_type := String(field["type"])
	if field_type == "option":
		var option := SetupOptionScene.instantiate() as OptionButton
		option.custom_minimum_size = _control_min_size(0.0, DESKTOP_CONTROL_HEIGHT)
		var selected_id := int(field.get("default", 0))
		var selected_index := 0
		var opts: Array = field.get("options", [])
		for i in range(opts.size()):
			var opt := opts[i] as Dictionary
			var id := int(opt.get("value", i))
			option.add_item(String(opt.get("label", str(id))), id)
			if id == selected_id:
				selected_index = i
		option.select(selected_index)
		option.item_selected.connect(func(_index: int) -> void: _on_field_changed())
		return option
	if field_type == "bool":
		var check := SetupBoolScene.instantiate() as CheckBox
		check.button_pressed = bool(field.get("default", false))
		check.custom_minimum_size = _control_min_size(0.0, DESKTOP_CONTROL_HEIGHT)
		check.toggled.connect(func(_pressed: bool) -> void: _on_field_changed())
		return check

	var min_value := float(field.get("min", 0.0))
	var max_value := _field_max_value(field)
	if field_type == "int" and is_equal_approx(min_value, 0.0) and is_equal_approx(max_value, 100.0):
		return _create_slider_spin_control(field)

	var spin := SetupSpinScene.instantiate() as SpinBox
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = float(field.get("step", 0.01))
	spin.value = float(field.get("default", 0.0))
	spin.rounded = field_type == "int"
	spin.custom_minimum_size = _control_min_size(120.0, 32.0)
	spin.size_flags_horizontal = Control.SIZE_SHRINK_END
	spin.value_changed.connect(func(_value: float) -> void: _on_number_field_changed())
	return spin


## BASE_FIELDS 是 const，装不下随平台变化的上限。地图尺寸在 web 上比桌面收得多
## （见 DCFeatureFlags.max_map_*），这里在建控件时把声明值再压一道，避免面板允许
## 玩家选到 NewGameConfig.validate 会直接拒绝的尺寸。
func _field_max_value(field: Dictionary) -> float:
	var declared := float(field.get("max", 1.0))
	match String(field.get("name", "")):
		"map_width":
			return minf(declared, float(DCFeatureFlags.max_map_width()))
		"map_height":
			return minf(declared, float(DCFeatureFlags.max_map_height()))
	return declared


func _create_slider_spin_control(field: Dictionary) -> Control:
	var wrap := SetupSliderSpinScene.instantiate() as HBoxContainer
	wrap.custom_minimum_size = _control_min_size(220.0, 32.0)

	var slider := wrap.get_node("Slider") as HSlider
	slider.min_value = float(field.get("min", 0.0))
	slider.max_value = float(field.get("max", 100.0))
	slider.step = float(field.get("step", 1.0))
	slider.value = float(field.get("default", 0.0))

	var spin := wrap.get_node("Spin") as SpinBox
	spin.min_value = slider.min_value
	spin.max_value = slider.max_value
	spin.step = slider.step
	spin.value = slider.value
	spin.rounded = true
	spin.custom_minimum_size = _control_min_size(72.0, 32.0)

	slider.value_changed.connect(func(value: float) -> void:
		if not is_equal_approx(spin.value, value):
			spin.value = value
		_on_number_field_changed()
	)
	spin.value_changed.connect(func(value: float) -> void:
		if not is_equal_approx(slider.value, value):
			slider.value = value
		_on_number_field_changed()
	)
	return wrap


func _apply_default_values() -> void:
	_syncing = true
	_preset_option.select(1)
	for field in BASE_FIELDS:
		_set_control_value(_base_controls[String(field["name"])], field.get("default"))
	for field in RENDER_FIELDS:
		_set_control_value(_render_controls[String(field["name"])], field.get("default"))
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
	var render = config.get("render", {})
	if render is Dictionary:
		for field in RENDER_FIELDS:
			var name := String(field["name"])
			if (render as Dictionary).has(name):
				_set_control_value(_render_controls[name], (render as Dictionary)[name])
	var controls = config.get("controls", {})
	if not (controls is Dictionary):
		controls = {}
	if controls is Dictionary:
		for group in CLIMATE_GROUPS:
			for field in group["fields"]:
				var name := String(field["name"])
				if (controls as Dictionary).has(name):
					_set_control_value(_climate_controls[name], (controls as Dictionary)[name])
	_syncing = false
	_enforce_range_pairs()
	_update_preset_from_size()
	_update_cell_count()


func _set_control_value(control: Control, value) -> void:
	if control is SpinBox:
		(control as SpinBox).value = float(value)
	elif control is CheckBox:
		(control as CheckBox).button_pressed = bool(value)
	elif control is OptionButton:
		var option := control as OptionButton
		var target_id := int(value)
		for i in range(option.get_item_count()):
			if option.get_item_id(i) == target_id:
				option.select(i)
				return
	elif control is HBoxContainer:
		for child in (control as HBoxContainer).get_children():
			if child is HSlider:
				(child as HSlider).value = float(value)
			elif child is SpinBox:
				(child as SpinBox).value = float(value)


func _control_value(control: Control, field_type: String):
	if control is SpinBox:
		var v := (control as SpinBox).value
		return int(round(v)) if field_type == "int" else float(v)
	if control is CheckBox:
		return (control as CheckBox).button_pressed
	if control is OptionButton:
		return (control as OptionButton).get_selected_id()
	if control is HBoxContainer:
		for child in (control as HBoxContainer).get_children():
			if child is SpinBox:
				var sv := (child as SpinBox).value
				return int(round(sv)) if field_type == "int" else float(sv)
		for child in (control as HBoxContainer).get_children():
			if child is HSlider:
				var hv := (child as HSlider).value
				return int(round(hv)) if field_type == "int" else float(hv)
	return null


func _pct(controls: Dictionary, name: String, default_value: float) -> float:
	return clampf(float(controls.get(name, default_value)) / 100.0, 0.0, 1.0)


func _mix(a: float, b: float, t: float) -> float:
	return lerpf(a, b, clampf(t, 0.0, 1.0))


func _mixi(a: int, b: int, t: float) -> int:
	return int(round(_mix(float(a), float(b), t)))


func _build_climate_overrides(controls: Dictionary) -> Dictionary:
	var continent_spacing := _pct(controls, "continent_spacing", 55.0)
	var island_amount := _pct(controls, "island_amount", 50.0)
	var coast_roughness := _pct(controls, "coast_roughness", 50.0)
	var relief_amount := _pct(controls, "relief_amount", 55.0)
	var mountain_amount := _pct(controls, "mountain_amount", 60.0)
	var valley_amount := _pct(controls, "valley_amount", 45.0)
	var wetness := _pct(controls, "wetness", 55.0)
	var coastal_wetness := _pct(controls, "coastal_wetness", 55.0)
	var rain_shadow := _pct(controls, "rain_shadow", 50.0)
	var lake_density := _pct(controls, "lake_density", 45.0)
	var lake_size := _pct(controls, "lake_size", 55.0)
	var river_density := _pct(controls, "river_density", 55.0)
	var short_rivers := _pct(controls, "short_rivers", 50.0)
	var volcano_amount := _pct(controls, "volcano_amount", 40.0)
	var offshore_strength: float = clampf((island_amount + coast_roughness) * 0.5, 0.0, 1.0)

	return {
		"continent_warp_amp": _mix(0.04, 0.30, coast_roughness),
		"main_separation_factor": _mix(0.62, 1.12, continent_spacing),
		"satellites_per_main": _mixi(0, 7, island_amount),
		"satellite_radius_min": _mix(0.26, 0.12, island_amount),
		"satellite_radius_max": _mix(0.48, 0.28, island_amount),
		"satellite_separation_factor": _mix(0.30, 0.80, continent_spacing),
		"offshore_amp": _mix(0.20, 0.70, offshore_strength),
		"meso_weight": _mix(0.12, 0.48, coast_roughness),
		"macro_relief_weight": _mix(0.08, 0.45, relief_amount),
		"ridge_boost_amp": _mix(0.25, 1.15, mountain_amount),
		"spl_iters": _mixi(0, 30, valley_amount),
		"spl_erodibility": _mix(0.35, 2.60, valley_amount),
		"spl_uplift_rate": _mix(0.04, 0.18, mountain_amount),
		"moisture_land_base": _mix(0.08, 0.30, wetness),
		"moisture_precip_gain": _mix(2.0, 4.8, wetness),
		"moisture_continental_dry": _mix(0.045, 0.012, wetness),
		# [zonal-envelope] 越湿→ITCZ/风暴路径增雨越强、极地抑雨越弱（保持单调）
		"moisture_itcz_wet_strength": _mix(0.6, 1.2, wetness),
		"moisture_stormtrack_wet_strength": _mix(0.3, 0.7, wetness),
		"moisture_polar_dry_strength": _mix(0.5, 0.25, wetness),
		"moisture_tropical_evap_boost": _mix(0.6, 1.4, wetness),
		"moisture_coastal_floor": _mix(0.25, 0.62, coastal_wetness),
		"coastal_moisture_boost": _mix(0.05, 0.38, coastal_wetness),
		"orographic_boost": _mix(0.35, 2.2, mountain_amount),
		"rain_shadow_threshold": _mix(0.22, 0.06, rain_shadow),
		"rain_shadow_factor": _mix(0.88, 0.28, rain_shadow),
		"rain_shadow_lookback": _mixi(1, 5, rain_shadow),
		"hydro_lake_min_cells": _mixi(16, 4, lake_density),
		"hydro_lake_min_depth": _mix(0.030, 0.010, lake_density),
		"hydro_lake_min_volume": _mix(0.50, 0.10, lake_density),
		"lake_seed_freq": _mix(0.090, 0.035, lake_size),
		"lake_seed_threshold": _mix(0.72, 0.48, lake_density),
		"lake_seed_depth": _mix(0.05, 0.16, lake_size),
		"lake_seed_min_interior": 0.12,
		"river_channel_init_cells": _mixi(30, 7, river_density),
		"hydro_river_min_length": _mixi(10, 3, short_rivers),
		"max_volcanoes": _mixi(0, 18, volcano_amount),
		"volcano_min_dist": _mixi(14, 3, volcano_amount),
		"volcano_min_land_h": _mix(0.78, 0.52, volcano_amount),
	}


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
	_set_control_value(_base_controls["initial_seed"], randi_range(1, 2147483647))


func _on_reset_pressed() -> void:
	_apply_default_values()
	_update_cell_count()
	_save_settings()


func _on_start_pressed() -> void:
	var config := _build_config()
	Engine.set_meta(WORLD_SETUP_META, config)
	_save_settings(config)
	get_tree().change_scene_to_file(MAIN_SCENE_PATH)


func _on_debug_pressed() -> void:
	var config := _build_config()
	Engine.set_meta(WORLD_SETUP_META, config)
	_save_settings(config)
	get_tree().change_scene_to_file(DEBUG_SCENE_PATH)


func _build_config() -> Dictionary:
	var base := {}
	for field in BASE_FIELDS:
		var name := String(field["name"])
		base[name] = _control_value(_base_controls[name], String(field["type"]))

	var render := {}
	for field in RENDER_FIELDS:
		var name := String(field["name"])
		render[name] = _control_value(_render_controls[name], String(field["type"]))

	var controls := {}
	for group in CLIMATE_GROUPS:
		for field in group["fields"]:
			var name := String(field["name"])
			controls[name] = _control_value(_climate_controls[name], String(field["type"]))

	return {
		"version": 4,
		"source": "world_setup",
		"base": base,
		"render": render,
		"controls": controls,
		"climate": _build_climate_overrides(controls),
	}


func _save_settings(config: Dictionary = {}) -> void:
	var data: Dictionary = config
	if data.is_empty():
		data = _build_config()
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))


func _enforce_range_pairs() -> void:
	# 当前启动页只暴露玩家向单项控制；底层 min/max 配对由 _build_climate_overrides 派生。
	pass


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
