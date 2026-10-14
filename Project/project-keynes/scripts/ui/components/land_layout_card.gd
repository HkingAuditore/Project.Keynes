extends Button
class_name LandLayoutCard

const PapercutReliefShader := preload("res://shaders/papercut_relief_map.gdshader")

var layout_id: String = "two"
var _emblem: Control
var _caption: Label
var _mat: ShaderMaterial


func _ready() -> void:
	_emblem = get_node_or_null("Margin/VBox/Emblem") as Control
	_caption = get_node_or_null("Margin/VBox/Caption") as Label
	if _emblem != null:
		_mat = ShaderMaterial.new()
		_mat.shader = PapercutReliefShader
		_emblem.material = _mat
		_emblem.draw.connect(_draw_emblem)
		_emblem.resized.connect(func() -> void: _emblem.queue_redraw())
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
	if _mat == null:
		return
	_mat.set_shader_parameter("map_center_bias", Vector2(0.5, 0.5))
	_mat.set_shader_parameter("compass_scale", 0.0)
	_mat.set_shader_parameter("show_outer_frame", false)
	_mat.set_shader_parameter("wetness", 0.60)
	_mat.set_shader_parameter("river_density", 0.35)
	_mat.set_shader_parameter("lake_density", 0.25)
	match layout_id:
		"single":
			_mat.set_shader_parameter("seed_val", 11.0)
			_mat.set_shader_parameter("num_continents", 1)
			_mat.set_shader_parameter("continent_size", 0.78)
			_mat.set_shader_parameter("sea_level", 0.42)
			_mat.set_shader_parameter("continent_spacing", 0.40)
			_mat.set_shader_parameter("island_amount", 0.25)
		"two":
			_mat.set_shader_parameter("seed_val", 23.0)
			_mat.set_shader_parameter("num_continents", 2)
			_mat.set_shader_parameter("continent_size", 0.52)
			_mat.set_shader_parameter("sea_level", 0.48)
			_mat.set_shader_parameter("continent_spacing", 0.88)
			_mat.set_shader_parameter("island_amount", 0.35)
		"multiple":
			_mat.set_shader_parameter("seed_val", 47.0)
			_mat.set_shader_parameter("num_continents", 4)
			_mat.set_shader_parameter("continent_size", 0.42)
			_mat.set_shader_parameter("sea_level", 0.50)
			_mat.set_shader_parameter("continent_spacing", 0.86)
			_mat.set_shader_parameter("island_amount", 0.45)
		"archipelago":
			_mat.set_shader_parameter("seed_val", 71.0)
			_mat.set_shader_parameter("num_continents", 6)
			_mat.set_shader_parameter("continent_size", 0.28)
			_mat.set_shader_parameter("sea_level", 0.54)
			_mat.set_shader_parameter("continent_spacing", 0.72)
			_mat.set_shader_parameter("island_amount", 0.92)
		_:
			_mat.set_shader_parameter("seed_val", 97.0)
			_mat.set_shader_parameter("num_continents", 3)
			_mat.set_shader_parameter("continent_size", 0.48)
			_mat.set_shader_parameter("sea_level", 0.48)
			_mat.set_shader_parameter("continent_spacing", 0.75)
			_mat.set_shader_parameter("island_amount", 0.50)
			_mat.set_shader_parameter("compass_uv", Vector2(0.5, 0.5))
			_mat.set_shader_parameter("compass_scale", 0.34)


func _refresh_visual() -> void:
	if _caption != null:
		_caption.add_theme_color_override(
			"font_color",
			UITokens.DOSSIER_OXBLOOD if button_pressed else UITokens.DOSSIER_INK
		)
	if _mat != null:
		_mat.set_shader_parameter("darken_veil", 0.0 if button_pressed else 0.16)
	if _emblem != null:
		_emblem.queue_redraw()


func _draw_emblem() -> void:
	if _emblem == null or _emblem.size.x <= 2.0 or _emblem.size.y <= 2.0:
		return
	if _mat != null:
		_mat.set_shader_parameter("viewport_size", _emblem.size * 2.4)
	_emblem.draw_rect(Rect2(Vector2.ZERO, _emblem.size), Color.WHITE)
