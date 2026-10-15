extends Button
class_name LandLayoutCard

const SeaChartShader := preload("res://shaders/sea_chart_astrolabe.gdshader")

var layout_id: String = "two"
var _emblem: Control
var _caption: Label
var _sea_rect: ColorRect
var _sea_mat: ShaderMaterial
var _stage: PaperAtlasStage


func _ready() -> void:
	_emblem = get_node_or_null("Margin/VBox/Emblem") as Control
	_caption = get_node_or_null("Margin/VBox/Caption") as Label
	if _emblem != null:
		_sea_rect = ColorRect.new()
		_sea_rect.mouse_filter = MOUSE_FILTER_IGNORE
		_sea_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_sea_mat = ShaderMaterial.new()
		_sea_mat.shader = SeaChartShader
		_sea_mat.set_shader_parameter("compact_mode", 1.0)
		_sea_mat.set_shader_parameter("show_neatline", 0.0)
		_sea_mat.set_shader_parameter("compass_uv", Vector2(0.82, 0.28))
		_sea_mat.set_shader_parameter("compass_scale", 0.24)
		_sea_rect.material = _sea_mat
		_emblem.add_child(_sea_rect)
		_emblem.resized.connect(func() -> void:
			if _sea_mat != null and _emblem != null:
				_sea_mat.set_shader_parameter("viewport_size", _emblem.size.max(Vector2.ONE))
		)

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
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 0.5)
