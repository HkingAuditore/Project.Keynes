extends Control

const PapercutReliefShader := preload("res://shaders/papercut_relief_map.gdshader")

var _mat: ShaderMaterial
var _target_reveal := 0.35
var _current_reveal := 0.35


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = PapercutReliefShader
	_mat.set_shader_parameter("seed_val", 37.0)
	_mat.set_shader_parameter("num_continents", 2)
	_mat.set_shader_parameter("continent_size", 0.56)
	_mat.set_shader_parameter("sea_level", 0.46)
	_mat.set_shader_parameter("continent_spacing", 0.82)
	_mat.set_shader_parameter("island_amount", 0.45)
	_mat.set_shader_parameter("wetness", 0.60)
	_mat.set_shader_parameter("river_density", 0.60)
	_mat.set_shader_parameter("lake_density", 0.45)
	_mat.set_shader_parameter("map_center_bias", Vector2(0.50, 0.50))
	_mat.set_shader_parameter("compass_uv", Vector2(0.50, 0.50))
	_mat.set_shader_parameter("compass_scale", 0.34)
	_mat.set_shader_parameter("darken_veil", 0.28)
	_mat.set_shader_parameter("reveal_progress", _current_reveal)
	_mat.set_shader_parameter("show_outer_frame", true)
	material = _mat
	set_process(true)
	resized.connect(_sync_size)
	_sync_size()


func set_loading_progress(fraction: float) -> void:
	_target_reveal = lerpf(0.32, 1.0, clampf(fraction, 0.0, 1.0))


func _sync_size() -> void:
	if _mat != null and size.x > 1.0 and size.y > 1.0:
		_mat.set_shader_parameter("viewport_size", size)
	queue_redraw()


func _process(delta: float) -> void:
	_current_reveal = lerpf(_current_reveal, _target_reveal, clampf(delta * 4.5, 0.0, 1.0))
	if _mat != null:
		_mat.set_shader_parameter("reveal_progress", _current_reveal)


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
