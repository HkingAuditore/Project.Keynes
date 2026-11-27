extends Control

## Configure the new-game form, procedural map layout, and author map preview.

const LandLayout = preload("res://scripts/ui/main_menu_land_layout.gd")
const AdvancedLabelScene := preload("res://scenes/ui/advanced_field_label.tscn")
const SetupSliderSpinScene := preload("res://scenes/ui/setup_slider_spin.tscn")
const CountryNamesPack := preload("res://data/country/default_country_names.tres")
const USER_MAPS_DIR := "user://maps"
const MAP_PRESETS := [
	{"label": "小型 40 × 28", "size": Vector2i(40, 28)},
	{"label": "标准 60 × 40", "size": Vector2i(60, 40)},
	{"label": "大型 100 × 64", "size": Vector2i(100, 64)},
	{"label": "自定义", "size": Vector2i(60, 40)},
]

@onready var _status_label: Label = %StatusLabel
@onready var _country_edit: LineEdit = %CountryEdit
@onready var _random_country_button: Button = %RandomCountryButton
@onready var _foreign_slider: HSlider = %ForeignSlider
@onready var _foreign_count_box: SpinBox = %ForeignCount
@onready var _seed_box: SpinBox = %SeedBox
@onready var _size_option: OptionButton = %SizeOption
@onready var _width_box: SpinBox = %WidthBox
@onready var _height_box: SpinBox = %HeightBox
@onready var _layout_option: OptionButton = %LayoutOption
@onready var _layout_cards_row: Container = %LayoutCardsRow
@onready var _layout_hint: Label = %LayoutHint
@onready var _advanced_grid: GridContainer = %AdvancedGrid
@onready var _map_preview: PanelContainer = %MapPreview
@onready var _map_source_option: OptionButton = %MapSourceOption
@onready var _pkmap_field: Control = %PkmapField
@onready var _pkmap_pick: OptionButton = %PkmapPickOption
@onready var _pkmap_path_label: Label = %PkmapPathLabel
@onready var _pkmap_meta_label: Label = %PkmapMetaLabel
@onready var _pkmap_dialog: FileDialog = %PkmapDialog
var _advanced_controls: Dictionary = {}
var _advanced_sliders: Dictionary = {}
var _layout_cards: Dictionary = {}
var _layout_syncing := false
var _foreign_syncing := false
var _pkmap_path := ""
var _pkmap_pick_syncing := false


func _configure_new_game_form() -> void:
	_foreign_count_box.min_value = NewGameConfig.MIN_FOREIGN_COUNT
	_foreign_count_box.max_value = NewGameConfig.MAX_FOREIGN_COUNT
	_foreign_count_box.value = NewGameConfig.DEFAULT_FOREIGN_COUNT
	_foreign_count_box.step = 1.0
	_foreign_count_box.rounded = true
	_foreign_slider.min_value = NewGameConfig.MIN_FOREIGN_COUNT
	_foreign_slider.max_value = NewGameConfig.MAX_FOREIGN_COUNT
	_foreign_slider.step = 1.0
	_foreign_slider.value = NewGameConfig.DEFAULT_FOREIGN_COUNT
	_foreign_slider.value_changed.connect(_on_foreign_slider_changed)
	_foreign_count_box.value_changed.connect(_on_foreign_box_changed)

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
	for key in ["wetness", "lake_density", "river_density", "volcano_amount"]:
		(_advanced_controls[key] as SpinBox).value_changed.connect(
			func(_value: float) -> void: _sync_map_preview(false))
	_apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	_configure_map_source_options()
	_configure_pkmap_dialog()
	_sync_map_preview(false)


func _pick_random_country_name() -> void:
	if CountryNamesPack == null:
		return
	var names: PackedStringArray = CountryNamesPack.display_names
	if names.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_country_edit.text = String(names[rng.randi_range(0, names.size() - 1)])
	_sync_map_preview(false)


func _on_foreign_slider_changed(value: float) -> void:
	if _foreign_syncing:
		return
	_foreign_syncing = true
	_foreign_count_box.value = round(value)
	_foreign_syncing = false
	_sync_map_preview(false)


func _on_foreign_box_changed(value: float) -> void:
	if _foreign_syncing:
		return
	_foreign_syncing = true
	_foreign_slider.value = round(value)
	_foreign_syncing = false
	_sync_map_preview(false)


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

	var wrap := SetupSliderSpinScene.instantiate() as HBoxContainer
	var slider := wrap.get_node("Slider") as HSlider
	var box := wrap.get_node("Spin") as SpinBox
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	box.min_value = minimum
	box.max_value = maximum
	box.step = step
	box.value = value
	box.rounded = step >= 1.0
	slider.value_changed.connect(func(v: float) -> void:
		if not is_equal_approx(box.value, v):
			box.value = v
	)
	box.value_changed.connect(func(v: float) -> void:
		if not is_equal_approx(slider.value, v):
			slider.value = v
	)
	_advanced_grid.add_child(wrap)
	_advanced_controls[key] = box
	_advanced_sliders[key] = slider


func _on_size_preset_selected(index: int) -> void:
	if _is_pkmap_source():
		return
	var custom := index == MAP_PRESETS.size() - 1
	_set_custom_size_enabled(custom)
	if not custom:
		var map_size: Vector2i = MAP_PRESETS[index].size
		_width_box.value = map_size.x
		_height_box.value = map_size.y
	_sync_map_preview(false)


func _configure_land_layout_options() -> void:
	_layout_option.clear()
	var card_children := _layout_cards_row.get_children()
	for index in range(NewGameConfig.LAND_LAYOUT_PRESETS.size()):
		var preset: Dictionary = NewGameConfig.LAND_LAYOUT_PRESETS[index]
		var layout_id := String(preset.get("id", ""))
		var label_str := String(preset.get("label", ""))
		var hint_str := String(preset.get("hint", ""))
		_layout_option.add_item(label_str)
		_layout_option.set_item_metadata(index, layout_id)
		_layout_option.set_item_tooltip(index, hint_str)
		if index < card_children.size() and card_children[index] is Button:
			var card := card_children[index] as Button
			if card.has_method("configure"):
				card.call("configure", layout_id, label_str, hint_str)
			card.pressed.connect(func() -> void: _apply_land_layout(layout_id))
			_layout_cards[layout_id] = card
	_layout_option.select(NewGameConfig.land_layout_index(NewGameConfig.DEFAULT_LAND_LAYOUT))
	_refresh_layout_hint()


func _on_land_layout_selected(index: int) -> void:
	if _layout_syncing:
		return
	var layout_id := String(_layout_option.get_item_metadata(index))
	_apply_land_layout(layout_id)


func _apply_land_layout(layout_id: String) -> void:
	LandLayout._apply_land_layout(self, layout_id)


func _sync_layout_cards(active_id: String) -> void:
	LandLayout._sync_layout_cards(self, active_id)


func _on_layout_spin_changed() -> void:
	if _layout_syncing:
		return
	var matched := _matched_land_layout_id()
	var select_index := NewGameConfig.land_layout_index(matched)
	if _layout_option.selected != select_index:
		_layout_option.select(select_index)
	_sync_layout_cards(matched)
	_refresh_layout_hint()
	_sync_map_preview(false)


func _matched_land_layout_id() -> String:
	return LandLayout._matched_land_layout_id(self)


func _refresh_layout_hint() -> void:
	LandLayout._refresh_layout_hint(self)


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
	for id_key in _layout_cards:
		var card := _layout_cards[id_key] as Button
		if card != null:
			card.disabled = pkmap
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
		if _advanced_sliders.has(key):
			(_advanced_sliders[key] as HSlider).editable = not pkmap
	_refresh_layout_hint()
	_sync_map_preview(true)


func _sync_map_preview(animate_reveal: bool = false) -> void:
	if _map_preview == null or not _advanced_controls.has("num_continents"):
		return
	var layout_id := String(_layout_option.get_item_metadata(_layout_option.selected)) \
		if _layout_option.selected >= 0 else NewGameConfig.DEFAULT_LAND_LAYOUT
	var preset := NewGameConfig.land_layout_by_id(layout_id)
	if _map_preview.has_method("set_preview_state"):
		_map_preview.call("set_preview_state", {
			"country_name": _country_edit.text,
			"foreign_count": int(_foreign_count_box.value),
			"map_width": int(_width_box.value),
			"map_height": int(_height_box.value),
			"seed": int(_seed_box.value),
			"land_layout": layout_id,
			"land_layout_label": String(preset.get("label", "自定义")),
			"num_continents": int((_advanced_controls.num_continents as SpinBox).value),
			"continent_size": float((_advanced_controls.continent_size as SpinBox).value),
			"sea_level": float((_advanced_controls.sea_level as SpinBox).value),
			"continent_spacing": int((_advanced_controls.continent_spacing as SpinBox).value),
			"island_amount": int((_advanced_controls.island_amount as SpinBox).value),
			"wetness": int((_advanced_controls.wetness as SpinBox).value),
			"lake_density": int((_advanced_controls.lake_density as SpinBox).value),
			"river_density": int((_advanced_controls.river_density as SpinBox).value),
			"volcano_amount": int((_advanced_controls.volcano_amount as SpinBox).value),
			"is_pkmap": _is_pkmap_source(),
			"pkmap_file": _pkmap_path.get_file(),
			"pkmap_meta": _pkmap_meta_label.text,
		}, animate_reveal)


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
		_sync_map_preview(false)
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
	_sync_map_preview(true)
