extends PanelContainer
class_name CountryActionBar


signal section_selected(section_id: String)

const BAR_HEIGHT := 74.0
const BUTTON_SIZE := Vector2(58.0, 54.0)
const COMPACT_BUTTON_WIDTH := 50.0
const ICON_SIZE := 44
const SECTIONS := [
	{"id": "technology", "label": "科技", "icon": &"hud.country.technology", "available": true},
	{"id": "ideology", "label": "理念", "icon": &"hud.country.ideology", "available": true},
	{"id": "economy", "label": "经济", "icon": &"hud.country.economy", "available": true},
	{"id": "military", "label": "军事", "icon": &"hud.country.military", "available": false},
	{"id": "diplomacy", "label": "外交", "icon": &"hud.country.diplomacy", "available": false},
]

var _buttons: Dictionary = {}
var _active_section := ""


func _ready() -> void:
	if not _buttons.is_empty():
		return
	name = "CountryActionBar"
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var row := $Sections as HBoxContainer
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	var scene_buttons := row.get_children()
	for index in range(SECTIONS.size()):
		var definition: Dictionary = SECTIONS[index]
		var section_id := String(definition.id)
		var available := bool(definition.available)
		var button := scene_buttons[index] as Button
		button.set_meta(&"ui_sound", &"fold")
		var tooltip := "%s（打开国家%s卷宗）" % [String(definition.label), String(definition.label)] \
			if available else "%s（尚未开放）" % String(definition.label)
		IconButton.configure(button, tooltip, true, false)
		button.text = ""
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not available
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
			if available else Control.CURSOR_ARROW
		var icon := button.get_node("Column/Icon") as TextureRect
		icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		icon.texture = IconCatalog.texture_for_key(definition.icon)
		icon.modulate = Color.WHITE if available else Color(0.76, 0.72, 0.64, 0.42)
		var caption := button.get_node("Column/Caption") as Label
		caption.text = String(definition.label)
		caption.visible = false
		if available:
			UIAnimation.bind_tactile_button(button)
			button.pressed.connect(func() -> void: section_selected.emit(section_id))
			button.mouse_entered.connect(_sync_button_visual.bind(section_id, true))
			button.mouse_exited.connect(_sync_button_visual.bind(section_id, false))
		_buttons[section_id] = button


func set_active(section_id: String) -> void:
	_active_section = section_id
	for id in _buttons:
		var button := _buttons[id] as Button
		if button != null and not button.disabled:
			var is_active := String(id) == section_id
			IconButton.set_active(button, is_active)
			_sync_button_visual(String(id), false)


func _sync_button_visual(section_id: String, hovered: bool) -> void:
	var button := _buttons.get(section_id) as Button
	if button == null or button.disabled:
		return
	var is_active := section_id == _active_section
	var icon := button.get_node_or_null("Column/Icon") as TextureRect
	if icon != null:
		icon.modulate = Color(1.08, 1.05, 0.98, 1.0) if (is_active or hovered) else Color.WHITE


func bar_height() -> float:
	return BAR_HEIGHT


func set_compact(compact: bool) -> void:
	for id in _buttons:
		var button := _buttons[id] as Button
		if button != null:
			button.custom_minimum_size = Vector2(
				COMPACT_BUTTON_WIDTH if compact else BUTTON_SIZE.x,
				BUTTON_SIZE.y
			)
