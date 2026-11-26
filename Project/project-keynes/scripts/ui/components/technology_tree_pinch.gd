extends RefCounted

## 科技树画布双指捏合缩放与滚轮缩放协作者：保持宿主行数与单指交互逻辑干净。

const ZOOM_MIN := 0.60
const ZOOM_MAX := 1.60
const WHEEL_STEP := 1.12

var zoom := 1.0
var _touches: Dictionary = {}
var _pinching := false
var _last_dist := 0.0
var _last_mid := Vector2.ZERO


func reset() -> void:
	zoom = 1.0
	_touches.clear()
	_pinching = false


func is_pinching() -> bool:
	return _pinching


func handle_input(host: Control, event: InputEvent, offset: Vector2) -> Dictionary:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
			if _touches.size() >= 2:
				_begin_pinch()
				return {"handled": true, "offset": offset, "cancel_pan": true}
		else:
			_touches.erase(st.index)
			if _touches.size() < 2:
				_pinching = false
		return {"handled": _pinching, "offset": offset, "cancel_pan": _pinching}
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if _touches.has(sd.index):
			_touches[sd.index] = sd.position
		if _touches.size() >= 2:
			if not _pinching:
				_begin_pinch()
			var pair := _touch_pair()
			var dist := pair[0].distance_to(pair[1])
			var mid := (pair[0] + pair[1]) * 0.5
			var new_offset := offset + (mid - _last_mid)
			if _last_dist > 8.0 and dist > 8.0:
				new_offset = _apply_zoom_at(mid, new_offset, zoom * (dist / _last_dist))
			_last_dist = dist
			_last_mid = mid
			host.queue_redraw()
			return {"handled": true, "offset": new_offset, "cancel_pan": true}
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var factor := WHEEL_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else (1.0 / WHEEL_STEP)
			var next_offset := _apply_zoom_at(mb.position, offset, zoom * factor)
			host.queue_redraw()
			return {"handled": true, "offset": next_offset, "cancel_pan": false}
	return {"handled": false, "offset": offset, "cancel_pan": false}


func _begin_pinch() -> void:
	if _touches.size() < 2:
		return
	var pair := _touch_pair()
	_pinching = true
	_last_dist = pair[0].distance_to(pair[1])
	_last_mid = (pair[0] + pair[1]) * 0.5


func _touch_pair() -> Array[Vector2]:
	var keys := _touches.keys()
	return [_touches[keys[0]] as Vector2, _touches[keys[1]] as Vector2]


func _apply_zoom_at(anchor: Vector2, offset: Vector2, target_zoom: float) -> Vector2:
	var clamped := clampf(target_zoom, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(clamped, zoom):
		return offset
	var content_pt := (anchor - offset) / maxf(zoom, 0.01)
	zoom = clamped
	return anchor - content_pt * zoom
