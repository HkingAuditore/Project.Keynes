extends Button
class_name LandLayoutCard

const CHART := preload("res://assets/ui/tabletop/chart.webp")

var layout_id: String = "two"
var _emblem: Control
var _caption: Label
var _stage: PaperAtlasStage


func _ready() -> void:
	_emblem = get_node_or_null("Margin/VBox/Emblem") as Control
	_caption = get_node_or_null("Margin/VBox/Caption") as Label
	if _emblem != null:
		var sheet := TextureRect.new()
		sheet.texture = CHART
		sheet.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sheet.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		sheet.mouse_filter = MOUSE_FILTER_IGNORE
		_emblem.add_child(sheet)
		sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		_stage = PaperAtlasStage.new()
		_stage.cache_size = Vector2i(192, 128)
		_stage.interactive_parallax = false
		_emblem.add_child(_stage)
		_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toggled.connect(func(_pressed: bool) -> void: _refresh_visual())
	mouse_entered.connect(_refresh_visual)
	mouse_exited.connect(_refresh_visual)
	UIAnimation.bind_tactile_button(self, get_node_or_null("Margin") as Control, 0.0)
	_apply_shader_preset()
	_refresh_visual()


func configure(p_id: String, p_label: String, p_hint: String) -> void:
	layout_id = p_id
	tooltip_text = p_hint
	if _caption == null:
		_caption = get_node_or_null("Margin/VBox/Caption") as Label
	if _caption != null:
		_caption.text = p_label
	_apply_shader_preset()
	_refresh_visual()


func _apply_shader_preset() -> void:
	if _stage == null:
		return
	if layout_id == NewGameConfig.CUSTOM_LAND_LAYOUT:
		_stage.set_layout_state({
			"seed": 73,
			"num_continents": 3,
			"continent_size": 0.46,
			"sea_level": 0.49,
			"continent_spacing": 84,
			"island_amount": 62,
		})
		return
	var preset: Dictionary = NewGameConfig.LAND_LAYOUT_PRESETS[1]
	for candidate: Dictionary in NewGameConfig.LAND_LAYOUT_PRESETS:
		if String(candidate.get("id", "")) == layout_id:
			preset = candidate
			break
	var state := preset.duplicate(true)
	state["seed"] = 19 + layout_id.hash() % 83
	_stage.set_layout_state(state)


func _refresh_visual() -> void:
	if _caption != null:
		_caption.add_theme_color_override(
			"font_color",
			UITokens.DOSSIER_OXBLOOD if button_pressed else UITokens.DOSSIER_INK
		)
