extends Control

const ButtonContentScene := preload("res://scenes/ui/main_menu_button_content.tscn")
const MenuButtonScene := preload("res://scenes/ui/main_menu_button.tscn")
const SaveSlotRowScene := preload("res://scenes/ui/save_slot_row.tscn")
const AdvancedLabelScene := preload("res://scenes/ui/advanced_field_label.tscn")
const SetupSliderSpinScene := preload("res://scenes/ui/setup_slider_spin.tscn")
const CountryNamesPack := preload("res://data/country/default_country_names.tres")

const HOME_PANEL_WIDTH := 396.0
const COMMAND_WIDTH := 280.0
const USER_MAPS_DIR := "user://maps"
const MAP_PRESETS := [
	{"label": "小型 40 × 28", "size": Vector2i(40, 28)},
	{"label": "标准 60 × 40", "size": Vector2i(60, 40)},
	{"label": "大型 100 × 64", "size": Vector2i(100, 64)},
	{"label": "自定义", "size": Vector2i(60, 40)},
]

@onready var _backdrop: Control = %Backdrop
@onready var _page_margin: MarginContainer = %PageMargin
@onready var _page_stack: Control = %PageStack
@onready var _home_tome_shell: Control = %HomeTomeShell
@onready var _home_spine: Control = %HomeSpine
@onready var _home_hinges: Control = %HomeHinges
@onready var _dual_spread: BoxContainer = %DualSpread
@onready var _right_column: Control = %RightColumn
@onready var _settings_spread: BoxContainer = %SettingsSpread
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
@onready var _load_slots: VBoxContainer = %LoadSlots
@onready var _map_source_option: OptionButton = %MapSourceOption
@onready var _pkmap_field: Control = %PkmapField
@onready var _pkmap_pick: OptionButton = %PkmapPickOption
@onready var _pkmap_path_label: Label = %PkmapPathLabel
@onready var _pkmap_meta_label: Label = %PkmapMetaLabel
@onready var _pkmap_dialog: FileDialog = %PkmapDialog
@onready var _volume_value_label: Label = %VolumeValueLabel

var _advanced_controls: Dictionary = {}
var _advanced_sliders: Dictionary = {}
var _layout_cards: Dictionary = {}
var _settings_controls: Dictionary = {}
var _layout_syncing := false
var _foreign_syncing := false
var _pkmap_path := ""
var _pkmap_pick_syncing := false
var _current_page_key := "home"


## 主菜单背景音乐。GameAudio 是 autoload，bank 可能还没加载完，
## 所以轮询 status 直到 ready 再播；始终不就绪就静默放弃（大厅静音不影响功能）。
## 离开菜单后由全局 GameAudio 继续播放，直到世界就绪后时代音乐接管。
func _start_hall_music() -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("play_music"):
		return
	for _attempt in range(30):
		if String(audio.status) == "ready":
			if audio.has_method("play_stone_age_suite"):
				audio.play_stone_age_suite(true, 0.0, 0.78, 0)
			else:
				audio.play_music(&"hall")
			return
		await get_tree().process_frame


func _ready() -> void:
	var brand_crest := find_child("Crest", true, false) as TextureRect
	if brand_crest != null:
		brand_crest.texture = IconCatalog.texture_for_key(&"family.workspace.crest")
	if OS.get_cmdline_user_args().has("--editor-tech-tree") or OS.get_cmdline_args().has("--editor-tech-tree"):
		call_deferred("_open_technology_authoring_editor")
		return
	_configure_new_game_form()
	_bind_settings_controls()
	_connect_static_actions()
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_show_home(false)
	call_deferred("_apply_responsive_layout")
	call_deferred("_start_hall_music")


func _open_technology_authoring_editor() -> void:
	get_tree().change_scene_to_file("res://scenes/tools/technology_tree_authoring_editor.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _current_page_key != "home":
		_show_home()
		get_viewport().set_input_as_handled()


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


func _bind_settings_controls() -> void:
	_settings_controls = {
		"window_mode": %WindowMode,
		"resolution": %Resolution,
		"vsync": %Vsync,
		"render_quality": %RenderQuality,
		"ui_scale": %UIScale,
		"volume": %Volume,
		"muted": %Muted,
		"reduce_motion": %ReduceMotion,
	}
	(%Volume as HSlider).value_changed.connect(func(val: float) -> void:
		if _volume_value_label != null:
			_volume_value_label.text = "%d%%" % int(round(val * 100.0))
	)


func _connect_static_actions() -> void:
	for button in [%NewGameButton, %LoadGameButton, %SettingsButton, %BrowsePkmapButton]:
		button.set_meta(&"ui_sound", &"open")
	for button in [%NewBackButton, %LoadBackButton, %SettingsBackButton, %QuitButton]:
		button.set_meta(&"ui_sound", &"close")
	for button in [%StartButton, %ApplySettingsButton]:
		button.set_meta(&"ui_sound", &"confirm")
	%AdvancedButton.set_meta(&"ui_sound", &"fold")
	%NewGameButton.pressed.connect(_show_new_game)
	%LoadGameButton.pressed.connect(_show_load_game)
	%SettingsButton.pressed.connect(_show_settings)
	%QuitButton.pressed.connect(GameFlow.quit_game)
	%NewBackButton.pressed.connect(_show_home)
	%LoadBackButton.pressed.connect(_show_home)
	%SettingsBackButton.pressed.connect(_show_home)
	%StartButton.pressed.connect(_start_new_game)
	%ApplySettingsButton.pressed.connect(_apply_settings)
	%RandomSeedButton.pressed.connect(func() -> void:
		_seed_box.value = NewGameConfig.random_seed()
		_sync_map_preview(true)
	)
	_random_country_button.pressed.connect(_pick_random_country_name)
	_country_edit.text_changed.connect(func(_txt: String) -> void: _sync_map_preview(false))
	_seed_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	_width_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	_height_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	%AdvancedButton.toggled.connect(func(open: bool) -> void:
		_advanced_grid.visible = open
		if open and not UIAnimation.reduced_motion():
			UIAnimation.crossfade(_advanced_grid, UITokens.ANIM_FAST)
	)
	%BrowsePkmapButton.pressed.connect(_browse_pkmap)
	_size_option.item_selected.connect(_on_size_preset_selected)
	_layout_option.item_selected.connect(_on_land_layout_selected)
	_map_source_option.item_selected.connect(func(_index: int) -> void: _refresh_map_source_ui())
	_pkmap_pick.item_selected.connect(_on_pkmap_pick_selected)
	_pkmap_dialog.file_selected.connect(_on_pkmap_file_selected)

	for entry in [
		[%NewGameButton, "新游戏", "plus", 20],
		[%LoadGameButton, "加载游戏", "history", 18],
		[%SettingsButton, "设置", "settings", 16],
		[%QuitButton, "退出", "close", 16],
	]:
		_decorate_chapter_button(entry[0], entry[1], entry[2], entry[3])

	for entry in [
		[%NewBackButton, "返回", "back", 15],
		[%StartButton, "开始游戏", "play", 16],
		[%LoadBackButton, "返回", "back", 15],
		[%SettingsBackButton, "返回", "back", 15],
		[%ApplySettingsButton, "应用", "confirm", 15],
		[%AdvancedButton, "高级地图设置", "settings", 14],
		[%BrowsePkmapButton, "浏览…", "world", 14],
	]:
		_decorate_text_button(entry[0], entry[1], entry[2], entry[3])
	IconButton.apply(%RandomSeedButton, &"action.refresh", 15, "随机地图种子")
	IconButton.apply(_random_country_button, &"action.refresh", 14, "随机国家名称")


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


func _apply_responsive_layout() -> void:
	var narrow := size.x < 760.0
	var compact_spread := size.x < 980.0
	var side_margin := 12 if narrow else (24 if compact_spread else 48)
	var top_margin := 12 if narrow else 28
	var bottom_margin := 38 if narrow else 34
	_page_margin.add_theme_constant_override("margin_left", side_margin)
	_page_margin.add_theme_constant_override("margin_right", side_margin)
	_page_margin.add_theme_constant_override("margin_top", top_margin)
	_page_margin.add_theme_constant_override("margin_bottom", bottom_margin)
	_status_label.offset_left = side_margin
	_status_label.offset_right = -side_margin

	var avail_w := maxf(280.0, size.x - float(side_margin * 2))
	var avail_h := maxf(320.0, size.y - float(top_margin + bottom_margin))
	var short_h := avail_h < 450.0
	if _home_tome_shell != null:
		var shell_w := minf(HOME_PANEL_WIDTH, avail_w)
		var shell_h := minf(avail_h - 8.0, clampf(size.y * 0.56, 368.0 if short_h else 428.0, 472.0))
		_home_tome_shell.custom_minimum_size = Vector2(shell_w, shell_h)
		var folio_surface := _home_tome_shell.get_node_or_null("FolioSurface") as ColorRect
		if folio_surface != null and folio_surface.material is ShaderMaterial:
			var fmat := folio_surface.material as ShaderMaterial
			fmat.set_shader_parameter("panel_size", Vector2(shell_w, shell_h))
			fmat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)
		var folio_margin := _home_tome_shell.get_node_or_null("TomeRow/FrontispiecePage/FolioMargin") as MarginContainer
		if folio_margin != null:
			folio_margin.add_theme_constant_override("margin_top", 16 if short_h else 26)
			folio_margin.add_theme_constant_override("margin_bottom", 20 if short_h else 30)
		var folio_col := _home_tome_shell.get_node_or_null("TomeRow/FrontispiecePage/FolioMargin/Column") as VBoxContainer
		if folio_col != null:
			folio_col.add_theme_constant_override("separation", 6 if short_h else 10)
	if _home_spine != null:
		_home_spine.visible = false
	if _home_hinges != null:
		_home_hinges.visible = false

	for grid_name in ["PolityGrid", "SourceAndSizeGrid", "DimensionAndSeedGrid"]:
		var grid := find_child(grid_name, true, false) as GridContainer
		if grid != null:
			grid.columns = 1 if size.x < 920.0 else 2
	if _layout_cards_row is GridContainer:
		(_layout_cards_row as GridContainer).columns = 3 if size.x < 1080.0 else 5
	_map_preview.get_node("Margin/Column/SummaryGrid").visible = not compact_spread
	_map_preview.get_node("Margin/Column/CanvasFrame").custom_minimum_size.y = 120.0 if compact_spread else 196.0
	_map_preview.get_node("Margin/Column/CanvasFrame/MapCanvas").custom_minimum_size.y = 120.0 if compact_spread else 182.0
	_map_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if compact_spread else Control.SIZE_EXPAND_FILL
	_right_column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if compact_spread else Control.SIZE_EXPAND_FILL
	if _dual_spread != null:
		_dual_spread.vertical = compact_spread
	if _right_column != null:
		_right_column.custom_minimum_size.x = 0.0 if compact_spread else avail_w * 0.48
	if _settings_spread != null:
		_settings_spread.vertical = compact_spread

	var slip_widths: Array[float] = [282.0, 270.0, 260.0, 250.0]
	var slip_heights := PackedFloat32Array([44.0, 42.0, 42.0, 42.0]) if short_h else PackedFloat32Array([52.0, 48.0, 48.0, 48.0])
	var cmd_idx := 0
	for node in get_tree().get_nodes_in_group("main_menu_commands"):
		if node is Button:
			var btn := node as Button
			btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var target_w: float = minf(slip_widths[mini(cmd_idx, slip_widths.size() - 1)], avail_w - 86.0)
			var target_h: float = float(slip_heights[mini(cmd_idx, slip_heights.size() - 1)])
			btn.custom_minimum_size = Vector2(target_w, target_h)
			var slip := btn.get_node_or_null("SlipSurface") as ColorRect
			if slip != null and slip.material is ShaderMaterial:
				(slip.material as ShaderMaterial).set_shader_parameter("button_size", Vector2(target_w, target_h))
			cmd_idx += 1


func _show_page(page: Control, page_key: String = "home", animate: bool = true) -> void:
	_status_label.text = ""
	_current_page_key = page_key
	if _backdrop != null and _backdrop.has_method("set_page_mode"):
		_backdrop.call("set_page_mode", page_key)
	for candidate in get_tree().get_nodes_in_group("main_menu_pages"):
		UIAnimation.cancel(candidate as Control)
		var c := candidate as Control
		c.visible = c == page
	if animate and is_inside_tree():
		var offset := Vector2(-20.0, 0.0) if page_key == "home" else Vector2(24.0, 0.0)
		UIAnimation.crossfade(page, 0.12) if UIAnimation.reduced_motion() else UIAnimation.page_flip_in(page, offset, UITokens.MENU_PAGE_TRANSITION)
	if page_key == "home" and animate and not UIAnimation.reduced_motion():
		UIAnimation.stagger_children_in(%NewGameButton.get_parent(),.035,8,.24)
	call_deferred("_apply_responsive_layout")
	call_deferred("_focus_default_for_page", page_key)


func _focus_default_for_page(page_key: String) -> void:
	match page_key:
		"home":
			if %NewGameButton != null and %NewGameButton.is_visible_in_tree():
				%NewGameButton.grab_focus()
		"new":
			if %StartButton != null and %StartButton.is_visible_in_tree():
				%StartButton.grab_focus()
		"load":
			if %LoadBackButton != null and %LoadBackButton.is_visible_in_tree():
				%LoadBackButton.grab_focus()
		"settings":
			if %ApplySettingsButton != null and %ApplySettingsButton.is_visible_in_tree():
				%ApplySettingsButton.grab_focus()


func _show_home(animate: bool = true) -> void:
	_show_page(%HomePage, "home", animate)


func _show_new_game() -> void:
	_refresh_user_pkmap_list()
	_sync_map_preview(true)
	_show_page(%NewGamePage, "new", true)


func _show_load_game() -> void:
	_show_page(%LoadGamePage, "load", true)
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
	var row := SaveSlotRowScene.instantiate() as Control
	var preview := row.get_node("%Preview") as TextureRect
	var empty_seal := row.get_node("%EmptySeal") as Label
	var slot_badge := row.get_node("%SlotBadge") as Label
	var saved_at_label := row.get_node("%SavedAtLabel") as Label
	var title_label := row.get_node("%TitleLabel") as Label
	var description := row.get_node("%Description") as Label
	var slot_id := String(slot.get("slot_id", ""))
	var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
	slot_badge.text = label
	if bool(slot.get("exists", false)):
		var cname := String(slot.get("country_name", "未知国家"))
		var day_num := str(slot.get("day", 0))
		var w_str := str(slot.get("width", 0))
		var h_str := str(slot.get("height", 0))
		var saved_at := String(slot.get("saved_at", "")).replace("T", " ")
		title_label.text = "%s · 第 %s 天" % [cname, day_num]
		saved_at_label.text = saved_at
		description.text = "%s × %s" % [w_str, h_str]
		if save_service != null and save_service.has_method("load_preview"):
			var result: Dictionary = save_service.call("load_preview", slot_id)
			if bool(result.get("ok", false)):
				var image := Image.new()
				if image.load_png_from_buffer(result.get("bytes", PackedByteArray())) == OK:
					preview.texture = ImageTexture.create_from_image(image)
					empty_seal.visible = false
	else:
		title_label.text = "空槽位"
		saved_at_label.text = ""
		description.text = ""
		empty_seal.visible = true
	var load_button := row.get_node("%LoadButton") as Button
	_configure_button(load_button, "加载", "history", func() -> void: _load_slot(slot_id), 14)
	load_button.disabled = not bool(slot.get("loadable", false))
	if bool(slot.get("exists", false)) and load_button.disabled:
		var reason := String(slot.get("reason", "版本不兼容"))
		load_button.tooltip_text = reason
		description.text += " · 不可用"
	_load_slots.add_child(row)


func _show_settings() -> void:
	_show_page(%SettingsPage, "settings", true)
	var current: Dictionary = GameSettings.values()
	_configure_option(_settings_controls.window_mode,
		["窗口", "无边框", "全屏"], ["windowed", "borderless", "fullscreen"], current.window_mode)
	_configure_option(_settings_controls.resolution,
		["1280 × 720", "1366 × 768", "1600 × 900", "1920 × 1080", "2560 × 1440"],
		[Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)],
		Vector2i(current.resolution_width, current.resolution_height))
	_configure_option(_settings_controls.render_quality,
		["自动", "低", "中", "高"], ["auto", "low", "medium", "high"], current.render_quality)
	_configure_option(_settings_controls.ui_scale,
		["80%", "100%", "125%", "150%"], [80, 100, 125, 150], current.ui_scale_percent)
	_settings_controls.vsync.button_pressed = bool(current.vsync)
	_settings_controls.volume.value = float(current.master_volume)
	if _volume_value_label != null:
		_volume_value_label.text = "%d%%" % int(round(float(current.master_volume) * 100.0))
	_settings_controls.muted.button_pressed = bool(current.master_muted)
	_settings_controls.reduce_motion.button_pressed = bool(current.get("reduce_motion",false))


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


func _make_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := MenuButtonScene.instantiate() as Button
	_configure_button(button, text_value, icon, callback, 15)
	return button


func _decorate_chapter_button(button: Button, title_value: String, icon: String, font_size: int) -> void:
	button.text = ""
	button.tooltip_text = title_value
	var content := button.get_node_or_null("Content") as MarginContainer
	if content == null:
		content = ButtonContentScene.instantiate() as MarginContainer
		button.add_child(content)
	content.add_theme_constant_override("margin_left", 8)
	content.add_theme_constant_override("margin_right", 18)
	content.add_theme_constant_override("margin_top", 2)
	content.add_theme_constant_override("margin_bottom", 6)
	var row := content.get_node("Row") as HBoxContainer
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 14)
	var icon_label := content.get_node("Row/Icon") as Label
	IconButton.apply_to_label(icon_label, StringName(icon), font_size)
	icon_label.custom_minimum_size = Vector2(38, 0)
	icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_label.add_theme_color_override("font_color", Color(0.99, 0.91, 0.70, 1.0))
	icon_label.add_theme_color_override("font_shadow_color", Color(0.16, 0.04, 0.02, 0.72))
	icon_label.add_theme_constant_override("shadow_offset_x", 0)
	icon_label.add_theme_constant_override("shadow_offset_y", 1)
	var text_label := content.get_node("Row/Label") as Label
	text_label.text = title_value
	text_label.add_theme_font_override("font", UITokens.dossier_font("serif"))
	text_label.add_theme_font_size_override("font_size", font_size)
	text_label.add_theme_color_override("font_color", Color(0.14, 0.075, 0.035, 1.0))
	text_label.add_theme_color_override("font_shadow_color", Color(1.0, 0.97, 0.88, 0.84))
	text_label.add_theme_constant_override("shadow_offset_x", 0)
	text_label.add_theme_constant_override("shadow_offset_y", 1)
	_bind_paper_slip_button(button, content)


func _bind_paper_slip_button(button: Button, content: Control) -> void:
	if button == null or button.has_meta("_paper_slip_bound"):
		return
	button.set_meta("_paper_slip_bound", true)
	var slip := button.get_node_or_null("SlipSurface") as ColorRect
	var slip_mat := slip.material as ShaderMaterial if slip != null else null
	var animate_slip := func(hovered: bool, pressed: bool) -> void:
		if not is_instance_valid(button):
			return
		if button.has_meta("_slip_tween"):
			var old_t = button.get_meta("_slip_tween")
			if old_t is Tween and (old_t as Tween).is_valid():
				(old_t as Tween).kill()
		var tw := button.create_tween()
		button.set_meta("_slip_tween", tw)
		tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		var h_target := 1.0 if hovered else 0.0
		var p_target := 1.0 if pressed else 0.0
		if slip_mat != null:
			tw.parallel().tween_method(
				func(v: float) -> void: slip_mat.set_shader_parameter("hover_amount", v),
				float(slip_mat.get_shader_parameter("hover_amount")),
				h_target,
				UITokens.ANIM_FAST
			)
			tw.parallel().tween_method(
				func(v: float) -> void: slip_mat.set_shader_parameter("press_amount", v),
				float(slip_mat.get_shader_parameter("press_amount")),
				p_target,
				0.08
			)
		if content != null and is_instance_valid(content):
			var ofs := Vector2(-1.5, -2.0) if (hovered and not pressed) else (Vector2(1.0, 1.0) if pressed else Vector2.ZERO)
			tw.parallel().tween_property(content, "position", ofs, UITokens.ANIM_FAST)
	button.mouse_entered.connect(func() -> void: animate_slip.call(true, button.is_pressed()))
	button.mouse_exited.connect(func() -> void: animate_slip.call(false, false))
	button.focus_entered.connect(func() -> void: animate_slip.call(true, false))
	button.focus_exited.connect(func() -> void: animate_slip.call(false, false))
	button.button_down.connect(func() -> void: animate_slip.call(true, true))
	button.button_up.connect(func() -> void: animate_slip.call(button.is_hovered(), false))


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
	if button.theme_type_variation == &"PKSealPrimaryButton":
		icon_label.add_theme_color_override("font_color", UITokens.PAPERCUT_SEAL_GOLD)
		text_label.add_theme_color_override("font_color", UITokens.PAPERCUT_SEAL_GOLD)
	UIAnimation.bind_tactile_button(button, content, 3.0)


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
	var resolved_id := String(preset.get("id", NewGameConfig.CUSTOM_LAND_LAYOUT))
	var select_index := NewGameConfig.land_layout_index(resolved_id)
	if _layout_option.selected != select_index:
		_layout_option.select(select_index)
	_sync_layout_cards(resolved_id)
	_layout_syncing = false
	_refresh_layout_hint()
	_sync_map_preview(true)


func _sync_layout_cards(active_id: String) -> void:
	for id_key in _layout_cards:
		var card := _layout_cards[id_key] as Button
		if card != null:
			card.set_pressed_no_signal(String(id_key) == active_id)
			if card.has_method("_refresh_visual"):
				card.call("_refresh_visual")


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
		_layout_hint.text = "作者地图已冻结河湖与陆地形状。"
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
		"reduce_motion": _settings_controls.reduce_motion.button_pressed,
	})
	_status_label.text = "设置已应用。" if bool(result.get("ok", false)) else String(result.message)
