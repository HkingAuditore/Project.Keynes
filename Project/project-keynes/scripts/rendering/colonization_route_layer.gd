extends Node2D
class_name ColonizationRouteLayer

const LINE_COLOR := Color(0.86, 0.64, 0.30, 0.96)
const LINE_CASING := Color(0.08, 0.055, 0.03, 0.90)
const TARGET_COLOR := Color(0.93, 0.76, 0.42, 1.0)

var _map: MapData
var _clock: WorldClock
var _hex_size := 22.0
var _wrap_period := 0.0
var _route := PackedInt32Array()
var _cumulative := PackedInt32Array()
var _departure_day := 0
var _due_day := 0
var _route_cost := 0
var _speed := 1
var _state := 0
var _last_day := -1


func set_context(map: MapData, clock: WorldClock, hex_size: float,
		wrap_period: float) -> void:
	_map = map
	_clock = clock
	_hex_size = hex_size
	_wrap_period = wrap_period
	queue_redraw()


func show_quote(detail: Dictionary) -> void:
	_route = detail.get("route_cells", PackedInt32Array())
	_cumulative = detail.get("cumulative_costs", PackedInt32Array())
	_departure_day = _clock.day_index() if _clock != null else 0
	_due_day = _departure_day + int(detail.get("travel_days", 1))
	_route_cost = int(detail.get("route_cost", 0))
	_speed = maxi(1, ceili(float(_route_cost) / maxi(1, _due_day - _departure_day)))
	_state = 1
	visible = not _route.is_empty()
	queue_redraw()


func show_expedition(snapshot: Dictionary) -> void:
	_route = snapshot.get("route_cells", PackedInt32Array())
	_cumulative = snapshot.get("cumulative_costs", PackedInt32Array())
	_departure_day = int(snapshot.get("departure_day", 0))
	_due_day = int(snapshot.get("due_day", _departure_day))
	_route_cost = int(snapshot.get("route_cost", 0))
	_speed = maxi(1, int(snapshot.get("speed", 1)))
	_state = int(snapshot.get("state", 1))
	visible = not _route.is_empty()
	queue_redraw()


func clear_route() -> void:
	_route.clear()
	_cumulative.clear()
	visible = false
	queue_redraw()


func _process(_delta: float) -> void:
	if not visible or _clock == null:
		return
	var day := _clock.day_index()
	if day != _last_day:
		_last_day = day
		queue_redraw()


func _draw() -> void:
	if _map == null or _route.size() < 2:
		return
	var points := PackedVector2Array()
	var previous_x := NAN
	for cell_idx in _route:
		var cell = _map.cell_at(int(cell_idx))
		if cell == null:
			continue
		var point := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		if not is_nan(previous_x) and _wrap_period > 0.0:
			point = HexUtils.nearest_display_world(point, previous_x, _wrap_period)
		points.append(point)
		previous_x = point.x
	if points.size() < 2:
		return
	draw_polyline(points, LINE_CASING, 6.0, true)
	draw_polyline(points, LINE_COLOR, 3.0, true)
	draw_circle(points[0], 6.5, LINE_CASING)
	draw_circle(points[0], 4.0, LINE_COLOR)
	draw_circle(points[-1], 8.0, LINE_CASING)
	draw_circle(points[-1], 5.0, TARGET_COLOR)
	var progress := _progress_cost()
	var marker := _point_at_cost(points, progress)
	draw_circle(marker, 7.0, LINE_CASING)
	draw_circle(marker, 4.5, Color(0.98, 0.88, 0.62, 1.0))


func _progress_cost() -> int:
	var day := _clock.day_index() if _clock != null else _departure_day
	if _state == 3:
		return clampi(maxi(0, _due_day - day) * _speed,
			0, _route_cost)
	return clampi(maxi(0, day - _departure_day) * _speed, 0, _route_cost)


func _point_at_cost(points: PackedVector2Array, cost: int) -> Vector2:
	if _cumulative.size() != points.size() or points.is_empty():
		return points[0] if not points.is_empty() else Vector2.ZERO
	for index in range(1, _cumulative.size()):
		if cost > int(_cumulative[index]):
			continue
		var low := int(_cumulative[index - 1])
		var high := int(_cumulative[index])
		var t := float(cost - low) / float(maxi(1, high - low))
		return points[index - 1].lerp(points[index], clampf(t, 0.0, 1.0))
	return points[-1]
