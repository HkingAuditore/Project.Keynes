# map_camera.gd
# 地图浏览相机：右键/中键拖拽平移，滚轮缩放
# 用法：作为主场景的 Camera2D，调用 set_world_bounds(rect) 限制可视范围

class_name MapCamera
extends Camera2D

@export var zoom_min: float = 0.25
@export var zoom_max: float = 3.0
@export var zoom_step: float = 1.15
@export var pan_button: MouseButton = MOUSE_BUTTON_RIGHT

var _is_panning: bool = false
var _world_bounds: Rect2 = Rect2()

func _ready() -> void:
	make_current()

func set_world_bounds(bounds: Rect2) -> void:
	_world_bounds = bounds
	_clamp_position()

func center_on_bounds() -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	position = _world_bounds.position + _world_bounds.size * 0.5

func fit_to_viewport(margin: float = 1.05) -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	var vp := get_viewport_rect().size
	var sx := vp.x / (_world_bounds.size.x * margin)
	var sy := vp.y / (_world_bounds.size.y * margin)
	var s := clampf(minf(sx, sy), zoom_min, zoom_max)
	zoom = Vector2(s, s)
	center_on_bounds()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == pan_button:
			_is_panning = mb.pressed
		elif mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_at(mb.position, zoom_step)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at(mb.position, 1.0 / zoom_step)
	elif event is InputEventMouseMotion and _is_panning:
		var mm := event as InputEventMouseMotion
		position -= mm.relative / zoom
		_clamp_position()

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var old_zoom := zoom.x
	var new_zoom := clampf(old_zoom * factor, zoom_min, zoom_max)
	if is_equal_approx(new_zoom, old_zoom):
		return
	var vp_center := get_viewport_rect().size * 0.5
	var world_before := position + (screen_pos - vp_center) / old_zoom
	zoom = Vector2(new_zoom, new_zoom)
	var world_after := position + (screen_pos - vp_center) / new_zoom
	position += world_before - world_after
	_clamp_position()

func _clamp_position() -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	# 视口在世界中的半尺寸（考虑当前缩放）
	var half_view := get_viewport_rect().size * 0.5 / zoom
	var min_p := _world_bounds.position + half_view
	var max_p := _world_bounds.position + _world_bounds.size - half_view
	# 如果地图比视口还小，则强制居中
	if min_p.x > max_p.x:
		position.x = _world_bounds.position.x + _world_bounds.size.x * 0.5
	else:
		position.x = clampf(position.x, min_p.x, max_p.x)
	if min_p.y > max_p.y:
		position.y = _world_bounds.position.y + _world_bounds.size.y * 0.5
	else:
		position.y = clampf(position.y, min_p.y, max_p.y)
