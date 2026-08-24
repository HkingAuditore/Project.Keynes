extends PanelContainer
class_name CountryActionBar


signal section_selected(section_id: String)

const BAR_HEIGHT := 74.0
const BUTTON_SIZE := Vector2(64.0, 56.0)
const COMPACT_BUTTON_WIDTH := 56.0
const ICON_SIZE := 24
const SECTIONS := [
	{"id": "technology", "label": "科技", "icon": &"country.technology", "available": true},
	{"id": "ideology", "label": "理念", "icon": &"country.politics", "available": true},
	{"id": "economy", "label": "经济", "icon": &"country.economy", "available": true},
	{"id": "military", "label": "军事", "icon": &"country.military", "available": false},
	{"id": "diplomacy", "label": "外交", "icon": &"country.diplomacy", "available": false},
]

var _buttons: Dictionary = {}


func _ready() -> void:
	if not _buttons.is_empty():
		return
	name = "CountryActionBar"
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var row := $Sections as HBoxContainer
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	var scene_buttons := row.get_children()
	for index in range(SECTIONS.size()):
		var definition: Dictionary = SECTIONS[index]
		var section_id := String(definition.id)
		var available := bool(definition.available)
		var button := scene_buttons[index] as Button
		var tooltip := String(definition.label) if available else "尚未开放"
		IconButton.configure(button, tooltip, true, false)
		button.text = ""
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not available
		var icon := button.get_node("Column/Icon") as TextureRect
		icon.texture = IconCatalog.texture_for_key(definition.icon)
		icon.modulate = UITokens.BRASS_HIGHLIGHT if available else UITokens.TEXT_FAINT
		var caption := button.get_node("Column/Caption") as Label
		caption.text = String(definition.label) if available else ""
		caption.visible = available
		caption.add_theme_color_override("font_color",
			UITokens.TEXT_MAIN if available else UITokens.TEXT_FAINT)
		if available:
			button.pressed.connect(func() -> void: section_selected.emit(section_id))
		_buttons[section_id] = button


func set_active(section_id: String) -> void:
	for id in _buttons:
		var button := _buttons[id] as Button
		if button != null and not button.disabled:
			IconButton.set_active(button, id == section_id)


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
