class_name WorldSkyBackground
extends Node2D

const SKY_SHADER: Shader = preload("res://shaders/world_sky_background.gdshader")
const DAYLIGHT_TAU := 6.283185307179586

var _map_bounds := Rect2()
var _profile: WorldLightingProfile
var _canvas_layer: CanvasLayer
var _panels: Array[Polygon2D] = []
var _material: ShaderMaterial
var _last_screen_bounds := Rect2(INF, INF, 0.0, 0.0)
var _last_view_size := Vector2.ZERO


func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = -1
	add_child(_canvas_layer)
	_material = ShaderMaterial.new()
	_material.shader = SKY_SHADER
	for i in range(4):
		var panel := Polygon2D.new()
		panel.material = _material
		panel.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		panel.visible = false
		_canvas_layer.add_child(panel)
		_panels.append(panel)
	set_process(false)


func setup(map_bounds: Rect2, profile: WorldLightingProfile, day_phase: float,
		day_night_enabled: bool) -> void:
	_map_bounds = map_bounds
	_profile = profile
	if _profile == null or _profile.day_background == null or _profile.night_background == null:
		for panel in _panels:
			panel.visible = false
		set_process(false)
		return
	_material.set_shader_parameter("day_background", _profile.day_background)
	_material.set_shader_parameter("night_background", _profile.night_background)
	set_global_time(day_phase, day_night_enabled)
	set_process(true)
	_refresh_panels(true)


func set_global_time(day_phase: float, day_night_enabled: bool) -> void:
	if _material == null or _profile == null:
		return
	var day_weight := 1.0
	if day_night_enabled:
		var sun_height := sin(DAYLIGHT_TAU * fposmod(day_phase, 1.0))
		day_weight = smoothstep(-0.14, 0.14, sun_height)
	_material.set_shader_parameter("day_weight", day_weight)


func _process(_delta: float) -> void:
	_refresh_panels(false)


func _refresh_panels(force: bool) -> void:
	if _profile == null or not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	var canvas_xform := get_viewport().get_canvas_transform()
	var world_xform := get_global_transform()
	var corners: Array[Vector2] = [
		canvas_xform * (world_xform * _map_bounds.position),
		canvas_xform * (world_xform * Vector2(_map_bounds.end.x, _map_bounds.position.y)),
		canvas_xform * (world_xform * _map_bounds.end),
		canvas_xform * (world_xform * Vector2(_map_bounds.position.x, _map_bounds.end.y)),
	]
	var left: float = corners[0].x
	var top: float = corners[0].y
	var right: float = corners[0].x
	var bottom: float = corners[0].y
	for point: Vector2 in corners:
		left = minf(left, point.x)
		top = minf(top, point.y)
		right = maxf(right, point.x)
		bottom = maxf(bottom, point.y)
	var screen_bounds := Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
	if not force and viewport_size == _last_view_size \
			and screen_bounds.position.distance_squared_to(_last_screen_bounds.position) < 0.25 \
			and screen_bounds.size.distance_squared_to(_last_screen_bounds.size) < 0.25:
		return
	_last_view_size = viewport_size
	_last_screen_bounds = screen_bounds
	var viewport_rect := Rect2(Vector2.ZERO, viewport_size)
	var inside := screen_bounds.intersection(viewport_rect)
	if inside.size.x <= 0.0 or inside.size.y <= 0.0:
		_set_panel(0, viewport_rect, viewport_size)
		for i in range(1, _panels.size()):
			_panels[i].visible = false
		return
	_set_panel(0, Rect2(0.0, 0.0, viewport_size.x, inside.position.y), viewport_size)
	_set_panel(1, Rect2(0.0, inside.end.y, viewport_size.x,
		maxf(0.0, viewport_size.y - inside.end.y)), viewport_size)
	_set_panel(2, Rect2(0.0, inside.position.y, inside.position.x, inside.size.y), viewport_size)
	_set_panel(3, Rect2(inside.end.x, inside.position.y,
		maxf(0.0, viewport_size.x - inside.end.x), inside.size.y), viewport_size)


func _set_panel(index: int, rect: Rect2, viewport_size: Vector2) -> void:
	var panel := _panels[index]
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		panel.visible = false
		return
	var end := rect.end
	panel.polygon = PackedVector2Array([
		rect.position, Vector2(end.x, rect.position.y), end, Vector2(rect.position.x, end.y),
	])
	panel.uv = PackedVector2Array([
		rect.position / viewport_size,
		Vector2(end.x, rect.position.y) / viewport_size,
		end / viewport_size,
		Vector2(rect.position.x, end.y) / viewport_size,
	])
	panel.visible = true
