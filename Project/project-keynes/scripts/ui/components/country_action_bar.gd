extends PanelContainer
class_name CountryActionBar


signal section_selected(section_id: String)

const BAR_HEIGHT := 60.0
const BUTTON_SIZE := Vector2(52.0, 44.0)
const COMPACT_BUTTON_WIDTH := 46.0
const ICON_SIZE := 28
const SECTIONS := [
	{"id": "technology", "label": "科技", "icon": &"country.technology"},
	{"id": "politics", "label": "政治", "icon": &"country.politics"},
	{"id": "economy", "label": "经济", "icon": &"country.economy"},
	{"id": "military", "label": "军事", "icon": &"country.military"},
	{"id": "diplomacy", "label": "外交", "icon": &"country.diplomacy"},
]

var _buttons: Dictionary = {}


func _ready() -> void:
	if not _buttons.is_empty():
		return
	name = "CountryActionBar"
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := UITokens.panel_style(Color(0.038, 0.032, 0.026, 0.975), UITokens.RADIUS_MD, UITokens.PANEL_BORDER)
	style.content_margin_left = UITokens.SPACE_SM
	style.content_margin_top = 5
	style.content_margin_right = UITokens.SPACE_SM
	style.content_margin_bottom = 5
	add_theme_stylebox_override("panel", style)
	var row := $Sections as HBoxContainer
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	var scene_buttons := row.get_children()
	for index in range(SECTIONS.size()):
		var definition: Dictionary = SECTIONS[index]
		var section_id := String(definition.id)
		var button := scene_buttons[index] as Button
		IconButton.configure(button, String(definition.label), true, false)
		button.text = ""
		button.focus_mode = Control.FOCUS_NONE
		var icon := button.get_node("Center/Icon") as TextureRect
		icon.texture = IconCatalog.texture_for_key(definition.icon)
		icon.modulate = UITokens.BRASS_HIGHLIGHT.lerp(UITokens.TEXT_MAIN, 0.30)
		button.pressed.connect(func() -> void: section_selected.emit(section_id))
		_buttons[section_id] = button


func set_active(section_id: String) -> void:
	for id in _buttons:
		var button := _buttons[id] as Button
		if button != null:
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
