extends Control
class_name PapercutAtlasBackdrop

const SeaChartShader := preload("res://shaders/sea_chart_astrolabe.gdshader")

var _sea_chart: ColorRect
var _sea_mat: ShaderMaterial
var _stage: PaperAtlasStage
var _page := "home"
var _loading := false


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_sea_chart = ColorRect.new()
	_sea_chart.mouse_filter = MOUSE_FILTER_IGNORE
	_sea_chart.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sea_mat = ShaderMaterial.new()
	_sea_mat.shader = SeaChartShader
	_sea_chart.material = _sea_mat
	add_child(_sea_chart)

	_stage = PaperAtlasStage.new()
	_stage.hero = not _loading
	_stage.interactive_parallax = not _loading
	add_child(_stage)

	resized.connect(_sync_viewport_size)
	visibility_changed.connect(_sync_motion_state)
	_sync_viewport_size()
	_sync_motion_state()


func set_page_mode(page_key: String) -> void:
	_page = page_key
	if _stage != null:
		_stage.visible = page_key == "home" or _loading
		_stage.interactive_parallax = (page_key == "home") and not _loading
	_sync_viewport_size()


func _sync_motion_state() -> void:
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)


func _sync_viewport_size() -> void:
	var vp := size.max(Vector2.ONE)
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("viewport_size", vp)
		if _loading:
			_sea_mat.set_shader_parameter("compass_uv", Vector2(0.50, 0.43))
			_sea_mat.set_shader_parameter("compass_scale", 0.32)
			_sea_mat.set_shader_parameter("secondary_rose_uv", Vector2(0.18, 0.26))
		elif _page == "home":
			_sea_mat.set_shader_parameter("compass_uv", Vector2(0.67, 0.48))
			_sea_mat.set_shader_parameter("compass_scale", 0.30)
			_sea_mat.set_shader_parameter("secondary_rose_uv", Vector2(0.38, 0.78))
		else:
			_sea_mat.set_shader_parameter("compass_uv", Vector2(0.50, 0.50))
			_sea_mat.set_shader_parameter("compass_scale", 0.28)
			_sea_mat.set_shader_parameter("secondary_rose_uv", Vector2(0.20, 0.80))
		_sea_mat.set_shader_parameter("show_neatline", 1.0)
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)
	if _stage != null:
		if _loading:
			_stage.position = Vector2(size.x * 0.11, size.y * 0.03)
			_stage.size = Vector2(size.x * 0.78, size.y * 0.74)
		else:
			_stage.position = Vector2(size.x * 0.31, size.y * 0.02)
			_stage.size = Vector2(size.x * 0.67, size.y * 0.94)
