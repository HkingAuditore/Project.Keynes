extends Control

const ButtonContentScene := preload("res://scenes/ui/main_menu_button_content.tscn")
const MenuButtonScene := preload("res://scenes/ui/main_menu_button.tscn")
const SaveSlotRowScene := preload("res://scenes/ui/save_slot_row.tscn")
const AdvancedLabelScene := preload("res://scenes/ui/advanced_field_label.tscn")
const AdvancedSpinScene := preload("res://scenes/ui/advanced_field_spin.tscn")

const PANEL_WIDTH := 520.0
const COMMAND_WIDTH := 300.0
const USER_MAPS_DIR := "user://maps"
const MAP_PRESETS := [
	{"label": "小型 40 x 28", "size": Vector2i(40, 28)},
	{"label": "标准 60 x 40", "size": Vector2i(60, 40)},
	{"label": "大型 100 x 64", "size": Vector2i(100, 64)},
	{"label": "自定义", "size": Vector2i(60, 40)},
]

@onready var _page_margin: MarginContainer = %PageMargin
@onready var _page_stack: Control = %PageStack
@onready var _status_label: Label = %StatusLabel
@onready var _country_edit: LineEdit = %CountryEdit
@onready var _foreign_count_box: SpinBox = %ForeignCount
@onready var _seed_box: SpinBox = %SeedBox
@onready var _size_option: OptionButton = %SizeOption
@onready var _width_box: SpinBox = %WidthBox
@onready var _height_box: SpinBox = %HeightBox
@onready var _layout_option: OptionButton = %LayoutOption
@onready var _layout_hint: Label = %LayoutHint
@onready var _advanced_grid: GridContainer = %AdvancedGrid
@onready var _load_slots: VBoxContainer = %LoadSlots
@onready var _map_source_option: OptionButton = %MapSourceOption
@onready var _pkmap_field: Control = %PkmapField
@onready var _pkmap_pick: OptionButton = %PkmapPickOption
@onready var _pkmap_path_label: Label = %PkmapPathLabel
@onready var _pkmap_meta_label: Label = %PkmapMetaLabel
@onready var _pkmap_dialog: FileDialog = %PkmapDialog

var _advanced_controls: Dictionary = {}
var _settings_controls: Dictionary = {}
var _layout_syncing := false
var _pkmap_path := ""
var _pkmap_pick_syncing := false


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--editor-tech-tree") or OS.get_cmdline_args().has("--editor-tech-tree"):
		call_deferred("_open_technology_authoring_editor")
		return
	set_process(true)
	_configure_new_game_form()
	_bind_settings_controls()
	_connect_static_actions()
	resized.connect(_apply_responsive_layout)
	_show_home()
	_apply_responsive_layout()

func _open_technology_authoring_editor() -> void:
	get_tree().change_scene_to_file("res://scenes/tools/technology_tree_authoring_editor.tscn")


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


func _configure_new_game_form() -> void:
	_foreign_count_box.min_value = NewGameConfig.MIN_FOREIGN_COUNT
	_foreign_count_box.max_value = NewGameConfig.MAX_FOREIGN_COUNT
	_foreign_count_box.value = NewGameConfig.DEFAULT_FOREIGN_COUNT
	_foreign_count_box.step = 1.0
	_foreign_count_box.rounded = true
	_seed_box.value = NewGameConfig.random_seed()
	for preset in MAP_PRESETS:
		_size_option.add_item(String(preset.label))
	_size_option.select(1)
	_configure_dimension_box(_width_box, 10, DCFeatureFlags.max_map_width(), 60)
	_configure_dimension_box(_height_box, 8, DCFeatureFlags.max_map_height(), 40)
	_set_custom_size_enabled(false)
	_configure_land_layout_options()
	_add_advanced_spin("大陆数量", "num_continents", 1, 8, 2)
	_add_advanced_spin("大陆规模", "continent_size", 0.2, 0.9, 0.50, 0.01)
	_add_advanced_spin("海平面", "sea_level", 0.1, 0.8, 0.50, 0.01)
	_add_advanced_spin("大陆分散度", "continent_spacing", 0, 100, 92)
	_add_advanced_spin("岛屿数量", "island_amount", 0, 100, 38)
	_add_advanced_spin("湿润程度", "wetness", 0, 100, 55)
	_add_advanced_spin("湖泊密度", "lake_density", 0, 100, 45)
	_add_advanced_spin("河流密度", "river_density", 0, 100, 55)
	_add_advanced_spin("火山数量", "volcano_amount", 0, 100, 40)
	for key in ["num_continents", "continent_size", "sea_level", "continent_spacing", "island_amount"]:
		(_advanced_controls[key] as SpinBox).value_changed.connect(
			func(_value: float) -> void: _on_layout_spin_changed())
	_apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	_configure_map_source_options()
	_configure_pkmap_dialog()


func _bind_settings_controls() -> void:
	_settings_controls = {
		"window_mode": %WindowMode,
		"resolution": %Resolution,
		"vsync": %Vsync,
		"render_quality": %RenderQuality,
		"ui_scale": %UIScale,
		"volume": %Volume,
		"muted": %Muted,
	}


func _connect_static_actions() -> void:
	%NewGameButton.pressed.connect(_show_new_game)
	%LoadGameButton.pressed.connect(_show_load_game)
	%SettingsButton.pressed.connect(_show_settings)
	%QuitButton.pressed.connect(GameFlow.quit_game)
	%NewBackButton.pressed.connect(_show_home)
	%LoadBackButton.pressed.connect(_show_home)
	%SettingsBackButton.pressed.connect(_show_home)
	%StartButton.pressed.connect(_start_new_game)
	%ApplySettingsButton.pressed.connect(_apply_settings)
	%RandomSeedButton.pressed.connect(func() -> void: _seed_box.value = NewGameConfig.random_seed())
	%AdvancedButton.toggled.connect(func(open: bool) -> void: _advanced_grid.visible = open)
	%BrowsePkmapButton.pressed.connect(_browse_pkmap)
	_size_option.item_selected.connect(_on_size_preset_selected)
	_layout_option.item_selected.connect(_on_land_layout_selected)
	_map_source_option.item_selected.connect(func(_index: int) -> void: _refresh_map_source_ui())
	_pkmap_pick.item_selected.connect(_on_pkmap_pick_selected)
	_pkmap_dialog.file_selected.connect(_on_pkmap_file_selected)
	for entry in [
		[%NewGameButton, "新游戏", "plus", 18],
		[%LoadGameButton, "加载游戏", "history", 18],
		[%SettingsButton, "设置", "settings", 18],
		[%QuitButton, "退出", "close", 18],
		[%NewBackButton, "返回", "back", 15],
		[%StartButton, "开始游戏", "play", 15],
		[%LoadBackButton, "返回", "back", 15],
		[%SettingsBackButton, "返回", "back", 15],
		[%ApplySettingsButton, "应用", "confirm", 15],
		[%AdvancedButton, "高级地图设置", "settings", 15],
		[%BrowsePkmapButton, "浏览…", "world", 15],
	]:
		_decorate_text_button(entry[0], entry[1], entry[2], entry[3])
	IconButton.apply(%RandomSeedButton, &"action.refresh", 16, "生成随机地图种子")


func _apply_responsive_layout() -> void:
	var narrow := size.x < 720.0
	var side_margin := 18 if narrow else 56
	var right_margin := 18 if narrow else 42
	_page_margin.add_theme_constant_override("margin_left", side_margin)
	_page_margin.add_theme_constant_override("margin_right", right_margin)
	_page_margin.add_theme_constant_override("margin_top", 24 if narrow else 42)
	_page_margin.add_theme_constant_override("margin_bottom", 66 if narrow else 34)
	_status_label.offset_left = side_margin
	_status_label.offset_right = -right_margin
	var content_width := minf(PANEL_WIDTH, maxf(260.0, size.x - side_margin - right_margin))
	_page_stack.custom_minimum_size.x = content_width
	for page in get_tree().get_nodes_in_group("main_menu_pages"):
		if page is ScrollContainer and page.get_child_count() > 0:
			(page.get_child(0) as Control).custom_minimum_size.x = content_width
	for node in get_tree().get_nodes_in_group("main_menu_commands"):
		if node is Button:
			(node as Button).custom_minimum_size.x = minf(COMMAND_WIDTH, content_width)


func _show_page(page: Control) -> void:
	_status_label.text = ""
	for candidate in get_tree().get_nodes_in_group("main_menu_pages"):
		(candidate as Control).visible = candidate == page
	call_deferred("_apply_responsive_layout")


func _show_home() -> void:
	_show_page(%HomePage)


func _show_new_game() -> void:
	_refresh_user_pkmap_list()
	_show_page(%NewGamePage)


func _show_load_game() -> void:
	_show_page(%LoadGamePage)
	for child in _load_slots.get_children():
		child.queue_free()
	var slots: Array = []
	var save_service := get_node_or_null("/root/GameSave")
	if save_service != null and save_service.has_method("list_slots"):
		slots = save_service.call("list_slots")
	else:
		for slot_id in ["manual_1", "manual_2", "manual_3", "autosave"]:
			slots.append({"slot_id": slot_id, "exists": false, "loadable": false})
	for slot in slots:
		_add_save_slot(slot, save_service)


func _add_save_slot(slot: Dictionary, save_service) -> void:
	var row := SaveSlotRowScene.instantiate() as HBoxContainer
	var preview := row.get_node("Preview") as TextureRect
	var description := row.get_node("Description") as Label
	var slot_id := String(slot.get("slot_id", ""))
	var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
	if bool(slot.get("exists", false)):
		description.text = "%s\n%s · 第 %s 天 · seed %s · %sx%s\n%s" % [label,
			String(slot.get("country_name", "未知国家")), str(slot.get("day", 0)),
			str(slot.get("seed", 0)), str(slot.get("width", 0)), str(slot.get("height", 0)),
			String(slot.get("saved_at", ""))]
		if save_service != null and save_service.has_method("load_preview"):
			var result: Dictionary = save_service.call("load_preview", slot_id)
			if bool(result.get("ok", false)):
				var image := Image.new()
				if image.load_png_from_buffer(result.get("bytes", PackedByteArray())) == OK:
					preview.texture = ImageTexture.create_from_image(image)
	else:
		description.text = "%s\n空槽位" % label
	var load_button := row.get_node("LoadButton") as Button
	_configure_button(load_button, "加载", "history", func() -> void: _load_slot(slot_id), 15)
	load_button.disabled = not bool(slot.get("loadable", false))
	if bool(slot.get("exists", false)) and load_button.disabled:
		load_button.tooltip_text = String(slot.get("reason", "存档损坏或版本不兼容"))
	_load_slots.add_child(row)


func _show_settings() -> void:
	_show_page(%SettingsPage)
	var current: Dictionary = GameSettings.values()
	_configure_option(_settings_controls.window_mode,
		["窗口", "无边框", "全屏"], ["windowed", "borderless", "fullscreen"], current.window_mode)
	_configure_option(_settings_controls.resolution,
		["1280 x 720", "1366 x 768", "1600 x 900", "1920 x 1080", "2560 x 1440"],
		[Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)],
		Vector2i(current.resolution_width, current.resolution_height))
	_configure_option(_settings_controls.render_quality,
		["自动", "低", "中", "高"], ["auto", "low", "medium", "high"], current.render_quality)
	_configure_option(_settings_controls.ui_scale,
		["80%", "100%", "125%", "150%"], [80, 100, 125, 150], current.ui_scale_percent)
	_settings_controls.vsync.button_pressed = bool(current.vsync)
	_settings_controls.volume.value = float(current.master_volume)
	_settings_controls.muted.button_pressed = bool(current.master_muted)


func _configure_option(option: OptionButton, labels: Array, values: Array, selected) -> void:
	option.clear()
	for index in range(labels.size()):
		option.add_item(String(labels[index]))
		option.set_item_metadata(index, values[index])
		if values[index] == selected:
			option.select(index)


func _configure_dimension_box(box: SpinBox, minimum: int, maximum: int, value: int) -> void:
	box.min_value = minimum
	box.max_value = maximum
	box.step = 1
	box.value = value
	box.rounded = true


func _add_advanced_spin(label_text: String, key: String, minimum: float,
		maximum: float, value: float, step: float = 1.0) -> void:
	var label := AdvancedLabelScene.instantiate() as Label
	label.text = label_text
	_advanced_grid.add_child(label)
	var box := AdvancedSpinScene.instantiate() as SpinBox
	box.min_value = minimum
	box.max_value = maximum
	box.value = value
	box.step = step
	box.rounded = step >= 1.0
	_advanced_grid.add_child(box)
	_advanced_controls[key] = box


func _make_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := MenuButtonScene.instantiate() as Button
	_configure_button(button, text_value, icon, callback, 15)
	return button


func _decorate_text_button(button: Button, text_value: String, icon: String, font_size: int) -> void:
	button.text = ""
	button.tooltip_text = text_value
	var content := button.get_node_or_null("Content") as MarginContainer
	if content == null:
		content = ButtonContentScene.instantiate() as MarginContainer
		button.add_child(content)
	var icon_label := content.get_node("Row/Icon") as Label
	IconButton.apply_to_label(icon_label, StringName(icon), font_size)
	var text_label := content.get_node("Row/Label") as Label
	text_label.text = text_value
	text_label.add_theme_font_size_override("font_size", font_size)


func _configure_button(button: Button, text_value: String, icon: String,
		callback: Callable, font_size: int) -> void:
	_decorate_text_button(button, text_value, icon, font_size)
	button.pressed.connect(callback)


func _on_size_preset_selected(index: int) -> void:
	if _is_pkmap_source():
		return
	var custom := index == MAP_PRESETS.size() - 1
	_set_custom_size_enabled(custom)
	if not custom:
		var map_size: Vector2i = MAP_PRESETS[index].size
		_width_box.value = map_size.x
		_height_box.value = map_size.y


func _configure_land_layout_options() -> void:
	_layout_option.clear()
	_layout_hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_layout_hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	for index in range(NewGameConfig.LAND_LAYOUT_PRESETS.size()):
		var preset: Dictionary = NewGameConfig.LAND_LAYOUT_PRESETS[index]
		_layout_option.add_item(String(preset.get("label", "")))
		_layout_option.set_item_metadata(index, String(preset.get("id", "")))
		_layout_option.set_item_tooltip(index, String(preset.get("hint", "")))
	_layout_option.select(NewGameConfig.land_layout_index(NewGameConfig.DEFAULT_LAND_LAYOUT))
	_refresh_layout_hint()


func _on_land_layout_selected(index: int) -> void:
	if _layout_syncing:
		return
	var layout_id := String(_layout_option.get_item_metadata(index))
	_apply_land_layout(layout_id)


func _apply_land_layout(layout_id: String) -> void:
	var preset := NewGameConfig.land_layout_by_id(layout_id)
	if preset.is_empty():
		return
	_layout_syncing = true
	if String(preset.get("id", "")) != NewGameConfig.CUSTOM_LAND_LAYOUT:
		(_advanced_controls.num_continents as SpinBox).value = int(preset.get("num_continents", 2))
		(_advanced_controls.continent_size as SpinBox).value = float(preset.get("continent_size", 0.50))
		(_advanced_controls.sea_level as SpinBox).value = float(preset.get("sea_level", 0.50))
		(_advanced_controls.continent_spacing as SpinBox).value = int(preset.get("continent_spacing", 55))
		(_advanced_controls.island_amount as SpinBox).value = int(preset.get("island_amount", 50))
	var select_index := NewGameConfig.land_layout_index(String(preset.get("id", NewGameConfig.CUSTOM_LAND_LAYOUT)))
	if _layout_option.selected != select_index:
		_layout_option.select(select_index)
	_layout_syncing = false
	_refresh_layout_hint()


func _on_layout_spin_changed() -> void:
	if _layout_syncing:
		return
	var matched := _matched_land_layout_id()
	var select_index := NewGameConfig.land_layout_index(matched)
	if _layout_option.selected != select_index:
		_layout_option.select(select_index)
	_refresh_layout_hint()


func _matched_land_layout_id() -> String:
	for preset in NewGameConfig.LAND_LAYOUT_PRESETS:
		var layout: Dictionary = preset
		if String(layout.get("id", "")) == NewGameConfig.CUSTOM_LAND_LAYOUT:
			continue
		if int((_advanced_controls.num_continents as SpinBox).value) != int(layout.get("num_continents", 0)):
			continue
		if not is_equal_approx(float((_advanced_controls.continent_size as SpinBox).value),
				float(layout.get("continent_size", 0.0))):
			continue
		if not is_equal_approx(float((_advanced_controls.sea_level as SpinBox).value),
				float(layout.get("sea_level", 0.0))):
			continue
		if int((_advanced_controls.continent_spacing as SpinBox).value) != int(layout.get("continent_spacing", 0)):
			continue
		if int((_advanced_controls.island_amount as SpinBox).value) != int(layout.get("island_amount", 0)):
			continue
		return String(layout.get("id", NewGameConfig.CUSTOM_LAND_LAYOUT))
	return NewGameConfig.CUSTOM_LAND_LAYOUT


func _refresh_layout_hint() -> void:
	if _is_pkmap_source():
		_layout_hint.text = "作者地图已冻结河湖与陆地形状。湿润程度仍影响开局后的气候。"
		return
	var layout_id := String(_layout_option.get_item_metadata(_layout_option.selected))
	var preset := NewGameConfig.land_layout_by_id(layout_id)
	_layout_hint.text = String(preset.get("hint", ""))


func _set_custom_size_enabled(enabled: bool) -> void:
	_width_box.editable = enabled
	_height_box.editable = enabled


func _configure_map_source_options() -> void:
	_map_source_option.clear()
	_map_source_option.add_item("程序生成")
	_map_source_option.set_item_metadata(0, NewGameConfig.MAP_SOURCE_PROCEDURAL)
	if not OS.has_feature("web"):
		_map_source_option.add_item("作者地图")
		_map_source_option.set_item_metadata(1, NewGameConfig.MAP_SOURCE_PKMAP)
	_map_source_option.select(0)
	_pkmap_path_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_pkmap_meta_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_pkmap_meta_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_refresh_user_pkmap_list()
	_refresh_map_source_ui()


func _configure_pkmap_dialog() -> void:
	_pkmap_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_pkmap_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_pkmap_dialog.use_native_dialog = true
	_pkmap_dialog.filters = PackedStringArray(["*.pkmap ; 作者地图"])
	_pkmap_dialog.title = "选择作者地图"


func _is_pkmap_source() -> bool:
	if _map_source_option.item_count <= 0 or _map_source_option.selected < 0:
		return false
	return String(_map_source_option.get_item_metadata(_map_source_option.selected)) \
		== NewGameConfig.MAP_SOURCE_PKMAP


func _refresh_map_source_ui() -> void:
	var pkmap := _is_pkmap_source()
	_pkmap_field.visible = pkmap
	_size_option.disabled = pkmap
	_layout_option.disabled = pkmap
	_seed_box.editable = not pkmap
	%RandomSeedButton.disabled = pkmap
	if pkmap:
		_width_box.editable = false
		_height_box.editable = false
		if _pkmap_path.is_empty() and _pkmap_pick.item_count > 0:
			_apply_pkmap_path(String(_pkmap_pick.get_item_metadata(0)))
		elif not _pkmap_path.is_empty() and _pkmap_meta_label.text.is_empty():
			_apply_pkmap_path(_pkmap_path)
	else:
		_set_custom_size_enabled(_size_option.selected == MAP_PRESETS.size() - 1)
	for key in ["num_continents", "continent_size", "sea_level", "continent_spacing",
			"island_amount", "lake_density", "river_density", "volcano_amount"]:
		if _advanced_controls.has(key):
			(_advanced_controls[key] as SpinBox).editable = not pkmap
	_refresh_layout_hint()


func _list_user_pkmaps() -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(USER_MAPS_DIR)
	if dir == null:
		return found
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and entry.ends_with(".pkmap"):
			found.append(ProjectSettings.globalize_path(USER_MAPS_DIR.path_join(entry)))
		entry = dir.get_next()
	dir.list_dir_end()
	return found


func _refresh_user_pkmap_list() -> void:
	var maps := _list_user_pkmaps()
	_pkmap_pick_syncing = true
	_pkmap_pick.clear()
	for path in maps:
		_pkmap_pick.add_item(String(path).get_file())
		_pkmap_pick.set_item_metadata(_pkmap_pick.item_count - 1, path)
	_pkmap_pick.visible = maps.size() > 0
	if not _pkmap_path.is_empty():
		_select_pkmap_pick(_pkmap_path)
	elif _is_pkmap_source() and maps.size() > 0:
		_pkmap_pick.select(0)
		_pkmap_pick_syncing = false
		_apply_pkmap_path(String(maps[0]))
		return
	_pkmap_pick_syncing = false


func _select_pkmap_pick(path: String) -> void:
	for index in range(_pkmap_pick.item_count):
		if String(_pkmap_pick.get_item_metadata(index)) == path:
			_pkmap_pick.select(index)
			return
	_pkmap_pick.add_item(path.get_file())
	_pkmap_pick.set_item_metadata(_pkmap_pick.item_count - 1, path)
	_pkmap_pick.select(_pkmap_pick.item_count - 1)
	_pkmap_pick.visible = true


func _on_pkmap_pick_selected(index: int) -> void:
	if _pkmap_pick_syncing or index < 0:
		return
	_apply_pkmap_path(String(_pkmap_pick.get_item_metadata(index)))


func _browse_pkmap() -> void:
	var start_dir := ProjectSettings.globalize_path(USER_MAPS_DIR)
	if DirAccess.dir_exists_absolute(start_dir):
		_pkmap_dialog.current_dir = start_dir
	_pkmap_dialog.popup_centered()


func _on_pkmap_file_selected(path: String) -> void:
	_apply_pkmap_path(path.strip_edges())


func _apply_pkmap_path(path: String) -> void:
	if path.is_empty():
		_pkmap_path = ""
		_pkmap_path_label.text = "尚未选择 .pkmap 文件"
		_pkmap_path_label.tooltip_text = ""
		_pkmap_meta_label.text = ""
		return
	var peeked: Dictionary = PkmapIO.peek_pkmap(path)
	if not bool(peeked.get("ok", false)):
		_status_label.text = String(peeked.get("message", "无法读取作者地图。"))
		_pkmap_meta_label.text = ""
		return
	var header: Dictionary = peeked.get("header", {})
	if String(header.get("generator_hash", "")) != SaveRepository.compatibility_hash():
		_status_label.text = "该作者地图与当前生成器不兼容。"
		_pkmap_meta_label.text = ""
		return
	_pkmap_path = path
	_pkmap_path_label.text = path.get_file()
	_pkmap_path_label.tooltip_text = path
	_width_box.value = int(peeked.get("width", _width_box.value))
	_height_box.value = int(peeked.get("height", _height_box.value))
	var packed_seed := int(peeked.get("seed", 0))
	if packed_seed != 0:
		_seed_box.value = packed_seed
	_pkmap_meta_label.text = "%d × %d · 种子 %d · %d 格" % [
		int(peeked.get("width", 0)),
		int(peeked.get("height", 0)),
		int(_seed_box.value),
		int(peeked.get("n_cells", 0)),
	]
	_status_label.text = ""
	_pkmap_pick_syncing = true
	_select_pkmap_pick(path)
	_pkmap_pick_syncing = false


func _start_new_game() -> void:
	var config := NewGameConfig.new()
	config.country.name = _country_edit.text
	config.country.foreign_count = int(_foreign_count_box.value)
	config.base.map_width = int(_width_box.value)
	config.base.map_height = int(_height_box.value)
	config.base.initial_seed = int(_seed_box.value)
	config.base.land_layout = String(_layout_option.get_item_metadata(_layout_option.selected))
	config.base.num_continents = int((_advanced_controls.num_continents as SpinBox).value)
	config.base.continent_size = float((_advanced_controls.continent_size as SpinBox).value)
	config.base.sea_level = float((_advanced_controls.sea_level as SpinBox).value)
	if _is_pkmap_source():
		config.base.map_source = NewGameConfig.MAP_SOURCE_PKMAP
		config.base.pkmap_path = _pkmap_path
	else:
		config.base.map_source = NewGameConfig.MAP_SOURCE_PROCEDURAL
		config.base.pkmap_path = ""
	config.world_controls = {
		"continent_spacing": int((_advanced_controls.continent_spacing as SpinBox).value),
		"island_amount": int((_advanced_controls.island_amount as SpinBox).value),
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
