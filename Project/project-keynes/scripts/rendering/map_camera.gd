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

func fit_to_viewport(margin: float = 1.05, safe_area: Rect2 = Rect2()) -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	# 若未传入 safe_area，则退化到整块 viewport（兼容旧调用）；
	# 否则用 UI 扣除后的"地图可见区域"算缩放，并把相机中心放到该区域中心，
	# 避免缩放后地图被 TopBar/RightPanel 裁掉半边。
	var vp_size := get_viewport_rect().size
	var area: Rect2 = safe_area
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		area = Rect2(Vector2.ZERO, vp_size)
	var sx := area.size.x / (_world_bounds.size.x * margin)
	var sy := area.size.y / (_world_bounds.size.y * margin)
	var s := clampf(minf(sx, sy), zoom_min, zoom_max)
	zoom = Vector2(s, s)
	# 让 safe_area 的中心对齐世界 bounds 的中心：
	# 相机 position = 世界中心 - (safe_area 中心相对 viewport 中心的偏移 / zoom)
	var world_center := _world_bounds.position + _world_bounds.size * 0.5
	var vp_center := vp_size * 0.5
	var area_center := area.position + area.size * 0.5
	var screen_offset := area_center - vp_center
	position = world_center - screen_offset / s
	_clamp_position()

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
