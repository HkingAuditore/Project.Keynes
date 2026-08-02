extends Control
class_name MapOverlayToolbar

const OverlayButtonScene := preload("res://scenes/ui/map_overlay_icon_button.tscn")

signal overlay_requested(request: Dictionary)
signal overlay_cleared()

const COLUMN_WIDTH := 56.0
const SECONDARY_WIDTH := 62.0
const BUTTON_SIZE := Vector2(44.0, 44.0)
const MAX_RESOURCE_PANEL_HEIGHT := 430.0
const PANEL_MARGIN_TOTAL := 12.0
const PANEL_THEME_MARGIN_TOTAL := 16.0

enum Category { NONE, GEOGRAPHY, CLIMATE, RESOURCES }

var _primary_panel: PanelContainer
var _secondary_panel: PanelContainer
var _primary_box: VBoxContainer
var _secondary_box: VBoxContainer
var _resource_scroll: ScrollContainer
var _category := Category.NONE
var _active_request: Dictionary = {}
var _technology_ids := PackedStringArray()
var _enforce_discovery := false
var _category_buttons: Dictionary = {}
var _mode_buttons: Array[Button] = []
var _close_button: Button
var _warned_missing_icons: Dictionary = {}


func _ready() -> void:
	_primary_panel = get_node_or_null("PrimaryPanel") as PanelContainer
	_secondary_panel = get_node_or_null("SecondaryPanel") as PanelContainer
	_primary_box = get_node_or_null("PrimaryPanel/Margin/PrimaryBox") as VBoxContainer
	_resource_scroll = get_node_or_null("SecondaryPanel/Margin/Root/ResourceScroll") as ScrollContainer
	_secondary_box = get_node_or_null("SecondaryPanel/Margin/Root/ResourceScroll/SecondaryBox") as VBoxContainer
	_close_button = get_node_or_null("SecondaryPanel/Margin/Root/CloseButton") as Button
	if _primary_panel == null or _secondary_panel == null or _primary_box == null \
			or _resource_scroll == null or _secondary_box == null or _close_button == null:
		push_error("MapOverlayToolbar 必须通过 map_overlay_toolbar.tscn 实例化。")
		return
	_configure_category_button(Category.GEOGRAPHY,
		_primary_box.get_node("Geography") as Button, &"geography.terrain",
		"地理信息", "显示海拔、地貌、气候区与当前植被")
	_configure_category_button(Category.CLIMATE,
		_primary_box.get_node("Climate") as Button, &"climate.weather",
		"气候信息", "显示实时温度、湿度、风向与洋流")
	_configure_category_button(Category.RESOURCES,
		_primary_box.get_node("Resources") as Button, &"economy.resource",
		"资源信息", "显示当前所有自然资源储量")
	IconButton.apply(_close_button, &"status.hidden", IconButton.LARGE,
		"关闭图层\n关闭当前地图信息遮罩")
	_close_button.pressed.connect(_on_clear_pressed)
	_resource_scroll.gui_input.connect(_on_resource_scroll_gui_input)


func set_resource_discovery_context(
	technology_ids: PackedStringArray,
	enforce_discovery: bool = false
) -> void:
	_technology_ids = technology_ids
	_enforce_discovery = enforce_discovery
	if _category == Category.RESOURCES:
		_rebuild_secondary()


func reset_for_world() -> void:
	_active_request.clear()
	_set_category(Category.NONE)


func dismiss_submenu() -> bool:
	if _category == Category.NONE:
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null and is_ancestor_of(focused):
			get_viewport().gui_release_focus()
			return true
		return false
	_set_category(Category.NONE)
	return true


func primary_safe_width() -> float:
	return COLUMN_WIDTH + UITokens.SPACE_MD


func _configure_category_button(category: int, button: Button,
		icon_key: StringName, title: String, description: String) -> void:
	IconButton.apply(button, icon_key, IconButton.LARGE,
		"%s\n%s" % [tr(title), tr(description)])
	button.pressed.connect(func() -> void:
		_set_category(Category.NONE if _category == category else category)
	)
	_category_buttons[category] = button


func _set_category(category: int) -> void:
	_category = category
	for key in _category_buttons:
		var category_button: Button = _category_buttons[key]
		category_button.button_pressed = int(key) == category
	if category == Category.NONE:
		if _secondary_panel.visible:
			UIAnimation.fade_slide_out(
				_secondary_panel, Vector2(-10.0, 0.0), UITokens.ANIM_FAST)
		return
	_rebuild_secondary()
	if not _secondary_panel.visible:
		UIAnimation.fade_slide_in(
			_secondary_panel, Vector2(-10.0, 0.0), UITokens.ANIM_FAST)


func _rebuild_secondary() -> void:
	for child in _secondary_box.get_children():
		_secondary_box.remove_child(child)
		child.queue_free()
	_mode_buttons.clear()

	match _category:
		Category.GEOGRAPHY:
			_add_mode_button(OverlayMode.MODE.ELEVATION, &"geography.elevation", "海拔",
				"显示各地区当前权威海拔")
			_add_mode_button(OverlayMode.MODE.LANDFORM, &"geography.surface", "地貌",
				"显示各地区当前地貌类型")
			_add_mode_button(OverlayMode.MODE.BIOME_GROUP, &"geography.terrain", "生物群系组",
				"显示各地区当前生物群系分组，不代表具体植被")
			_add_mode_button(OverlayMode.MODE.VEGETATION_TYPE, &"ecology.vegetation", "当前植被",
				"显示各地区当前植被类型")
		Category.CLIMATE:
			_add_mode_button(OverlayMode.MODE.TEMPERATURE, &"climate.temperature", "温度",
				"显示各地区当前温度")
			_add_mode_button(OverlayMode.MODE.HUMIDITY, &"climate.humidity", "湿度",
				"显示各地区当前空气与地表湿润程度")
			_add_mode_button(OverlayMode.MODE.WIND_DIR, &"climate.wind", "风向",
				"以色相表示方向、亮度表示风力")
			_add_mode_button(OverlayMode.MODE.OCEAN_CURRENT_DIR, &"hydrology.current", "洋流",
				"以色相表示方向、亮度表示流速")
		Category.RESOURCES:
			_add_resource_buttons()

	_apply_secondary_geometry()
	call_deferred("_wire_focus_neighbors")
	call_deferred("_configure_scrollbar")


func _apply_secondary_geometry() -> void:
	if _secondary_panel == null or _resource_scroll == null:
		return
	var count := _mode_buttons.size()
	var list_height := float(count) * BUTTON_SIZE.y + \
		float(maxi(count - 1, 0)) * UITokens.SPACE_XS
	var fixed_height := PANEL_THEME_MARGIN_TOTAL + PANEL_MARGIN_TOTAL \
		+ BUTTON_SIZE.y + UITokens.SPACE_XS
	var desired_height := fixed_height + list_height
	var available_height := maxf(
		BUTTON_SIZE.y * 2.0 + fixed_height,
		size.y
	)
	var panel_height := desired_height
	if _category == Category.RESOURCES:
		panel_height = minf(
			desired_height,
			minf(MAX_RESOURCE_PANEL_HEIGHT, available_height)
		)
	_secondary_panel.custom_minimum_size = Vector2(SECONDARY_WIDTH, panel_height)
	_secondary_panel.size = Vector2(SECONDARY_WIDTH, panel_height)
	_secondary_panel.offset_bottom = panel_height
	_resource_scroll.custom_minimum_size = Vector2(
		BUTTON_SIZE.x,
		maxf(BUTTON_SIZE.y, panel_height - fixed_height)
	)


func _configure_scrollbar() -> void:
	if not is_instance_valid(_resource_scroll):
		return
	var bar := _resource_scroll.get_v_scroll_bar()
	bar.custom_minimum_size.x = 5.0
	bar.mouse_filter = Control.MOUSE_FILTER_STOP


func _on_resource_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index in [
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN
	]:
		accept_event()


func layout_diagnostics() -> Dictionary:
	var scroll_bar := _resource_scroll.get_v_scroll_bar() \
		if is_instance_valid(_resource_scroll) else null
	return {
		"category": _category,
		"secondary_visible": is_instance_valid(_secondary_panel) and _secondary_panel.visible,
		"secondary_rect": Rect2(_secondary_panel.global_position, _secondary_panel.size) \
			if is_instance_valid(_secondary_panel) else Rect2(),
		"secondary_height": _secondary_panel.size.y \
			if is_instance_valid(_secondary_panel) else 0.0,
		"scroll_max": scroll_bar.max_value if scroll_bar != null else 0.0,
		"scroll_page": scroll_bar.page if scroll_bar != null else 0.0,
		"close_visible": is_instance_valid(_close_button) and _close_button.visible,
	}


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready() \
			and is_instance_valid(_secondary_panel) and _category != Category.NONE:
		call_deferred("_apply_secondary_geometry")


func _add_mode_button(
		mode: int,
		icon_key: StringName,
		title: String,
		description: String
) -> void:
	var button := _make_icon_button(icon_key, title, description)
	button.button_pressed = int(_active_request.get("mode", -1)) == mode
	button.pressed.connect(func() -> void:
		_activate({"mode": mode, "resource_id": &""}, button)
	)
	_secondary_box.add_child(button)
	_mode_buttons.append(button)


func _add_resource_buttons() -> void:
	for profile in ResourceProfileRegistry.ordered():
		if profile == null:
			continue
		if _enforce_discovery and not ResourceProfileRegistry.discovery_visible(
				profile, _technology_ids):
			continue
		var icon_key := ResourceProfileRegistry.icon_key(profile)
		var button := _make_icon_button(
			icon_key, profile.display_name,
			"显示各地区当前%s相对储量" % profile.display_name
		)
		if profile.icon != null:
			button.icon = profile.icon
			button.text = ""
			button.expand_icon = true
			button.icon_max_width = 24
		elif icon_key == &"system.unknown" and not _warned_missing_icons.has(profile.id):
			_warned_missing_icons[profile.id] = true
			push_warning("MapOverlayToolbar: resource '%s' has no registered icon" % profile.id)
		var request := {
			"mode": OverlayMode.MODE.RESOURCE_RESERVE,
			"resource_id": profile.id,
		}
		button.button_pressed = _active_request == request
		button.pressed.connect(func() -> void: _activate(request, button))
		_secondary_box.add_child(button)
		_mode_buttons.append(button)


func _make_icon_button(icon_key: StringName, title: String, description: String) -> Button:
	var button := OverlayButtonScene.instantiate() as Button
	button.tooltip_text = "%s\n%s" % [tr(title), tr(description)]
	IconButton.apply(button, icon_key, IconButton.LARGE)
	return button


func _activate(request: Dictionary, source: Button) -> void:
	_active_request = request.duplicate()
	for button in _mode_buttons:
		button.button_pressed = button == source
	overlay_requested.emit(_active_request.duplicate())


func _on_clear_pressed() -> void:
	_active_request.clear()
	for button in _mode_buttons:
		button.button_pressed = false
	overlay_cleared.emit()


func _wire_focus_neighbors() -> void:
	if _mode_buttons.is_empty() or not _category_buttons.has(_category) \
			or not is_instance_valid(_close_button):
		return
	var category_button: Button = _category_buttons[_category]
	var first: Button = _mode_buttons[0]
	category_button.focus_neighbor_right = category_button.get_path_to(first)
	for button in _mode_buttons:
		button.focus_neighbor_left = button.get_path_to(category_button)
	_close_button.focus_neighbor_left = _close_button.get_path_to(category_button)
