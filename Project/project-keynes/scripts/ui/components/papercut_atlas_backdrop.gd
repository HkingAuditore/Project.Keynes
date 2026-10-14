extends Control
class_name PapercutAtlasBackdrop

const PapercutReliefShader := preload("res://shaders/papercut_relief_map.gdshader")

var _mat: ShaderMaterial
var _parallax_current := Vector2.ZERO
var _parallax_target := Vector2.ZERO
var _focus_blend := 0.0
var _focus_target := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = PapercutReliefShader
	_mat.set_shader_parameter("seed_val", 29.0)
	_mat.set_shader_parameter("num_continents", 2)
	_mat.set_shader_parameter("continent_size", 0.58)
	_mat.set_shader_parameter("sea_level", 0.45)
	_mat.set_shader_parameter("continent_spacing", 0.78)
	_mat.set_shader_parameter("island_amount", 0.48)
	_mat.set_shader_parameter("wetness", 0.62)
	_mat.set_shader_parameter("river_density", 0.65)
	_mat.set_shader_parameter("lake_density", 0.45)
	_mat.set_shader_parameter("map_center_bias", Vector2(0.66, 0.50))
	_mat.set_shader_parameter("compass_uv", Vector2(0.68, 0.50))
	_mat.set_shader_parameter("compass_scale", 0.27)
	_mat.set_shader_parameter("show_outer_frame", true)
	material = _mat
	set_process(true)
	resized.connect(_sync_viewport_size)
	_sync_viewport_size()


func set_page_mode(page_key: String) -> void:
	_focus_target = 0.0 if page_key == "home" else 1.0


func _sync_viewport_size() -> void:
	if _mat != null and size.x > 1.0 and size.y > 1.0:
		_mat.set_shader_parameter("viewport_size", size)
	queue_redraw()


func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	if vp.x > 1.0 and vp.y > 1.0:
		var mouse := get_viewport().get_mouse_position()
		_parallax_target = Vector2(
			clampf((mouse.x / vp.x - 0.5) * 2.0, -1.0, 1.0),
			clampf((mouse.y / vp.y - 0.5) * 2.0, -1.0, 1.0)
		)
	_parallax_current = _parallax_current.lerp(_parallax_target, clampf(delta * 5.0, 0.0, 1.0))
	_focus_blend = lerpf(_focus_blend, _focus_target, clampf(delta * 5.5, 0.0, 1.0))
	if _mat != null:
		_mat.set_shader_parameter("parallax_offset", _parallax_current)
		_mat.set_shader_parameter("darken_veil", _focus_blend)
		_mat.set_shader_parameter("compass_uv", Vector2(lerpf(0.68, 0.76, _focus_blend), 0.50))
		_mat.set_shader_parameter("compass_scale", lerpf(0.27, 0.21, _focus_blend))


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
