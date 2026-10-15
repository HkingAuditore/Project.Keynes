extends Node2D
class_name ColonizationRouteLayer

const LINE_COLOR := Color(0.86, 0.64, 0.30, 0.96)
const LINE_CASING := Color(0.08, 0.055, 0.03, 0.90)
const TARGET_COLOR := Color(0.93, 0.76, 0.42, 1.0)
const CANDIDATE_SOURCE_COLOR := Color(0.26, 0.64, 0.52, 0.92)
const SELECTED_SOURCE_COLOR := Color(1.0, 1.0, 1.0, 1.0)

var _map: MapData
var _clock: WorldClock
var _hex_size := 22.0
var _wrap_period := 0.0
var _route := PackedInt32Array()
var _cumulative := PackedInt32Array()
var _candidate_sources := PackedInt32Array()
var _selected_source := -1
var _selected_target := -1
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


func set_planning_context(candidate_sources: PackedInt32Array,
		selected_source: int, target_cell: int) -> void:
	_candidate_sources = candidate_sources.duplicate()
	_selected_source = selected_source
	_selected_target = target_cell
	_sync_visibility()
	queue_redraw()


func clear_planning_context() -> void:
	_candidate_sources.clear()
	_selected_source = -1
	_selected_target = -1
	_sync_visibility()
	queue_redraw()


func show_quote(detail: Dictionary) -> void:
	_route = detail.get("route_cells", PackedInt32Array())
	_cumulative = detail.get("cumulative_costs", PackedInt32Array())
	_departure_day = _clock.day_index() if _clock != null else 0
	_due_day = _departure_day + int(detail.get("travel_days", 1))
	_route_cost = int(detail.get("route_cost", 0))
	_speed = maxi(1, ceili(float(_route_cost) / maxi(1, _due_day - _departure_day)))
	_state = 1
	_sync_visibility()
	queue_redraw()


func show_expedition(snapshot: Dictionary) -> void:
	_route = snapshot.get("route_cells", PackedInt32Array())
	_cumulative = snapshot.get("cumulative_costs", PackedInt32Array())
	_departure_day = int(snapshot.get("departure_day", 0))
	_due_day = int(snapshot.get("due_day", _departure_day))
	_route_cost = int(snapshot.get("route_cost", 0))
	_speed = maxi(1, int(snapshot.get("speed", 1)))
	_state = int(snapshot.get("state", 1))
	_sync_visibility()
	queue_redraw()


func clear_route() -> void:
	_route.clear()
	_cumulative.clear()
	_sync_visibility()
	queue_redraw()


func _sync_visibility() -> void:
	visible = not _route.is_empty() or not _candidate_sources.is_empty() \
		or _selected_source >= 0 or _selected_target >= 0


func _process(_delta: float) -> void:
	if not visible or _clock == null:
		return
	var day := _clock.day_index()
	if day != _last_day:
		_last_day = day
		queue_redraw()


func _cell_world_pos(cell_idx: int, ref_x: float = NAN) -> Vector2:
	if _map == null or cell_idx < 0:
		return Vector2(NAN, NAN)
	var cell = _map.cell_at(cell_idx)
	if cell == null:
		return Vector2(NAN, NAN)
	var point := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	if not is_nan(ref_x) and _wrap_period > 0.0:
		point = HexUtils.nearest_display_world(point, ref_x, _wrap_period)
	return point


func _draw() -> void:
	if _map == null:
		return
	var ref_x := NAN
	if _selected_target >= 0:
		var t_pos := _cell_world_pos(_selected_target)
		if not is_nan(t_pos.x):
			ref_x = t_pos.x
			var r_target := _hex_size * 0.68
			draw_arc(t_pos, r_target, 0.0, TAU, 36, LINE_CASING, 4.6, true)
			draw_arc(t_pos, r_target, 0.0, TAU, 36, TARGET_COLOR, 2.4, true)
			if _route.size() < 2:
				draw_circle(t_pos, 5.5, LINE_CASING)
				draw_circle(t_pos, 3.8, TARGET_COLOR)

	for src_cell in _candidate_sources:
		var s_pos := _cell_world_pos(int(src_cell), ref_x)
		if is_nan(s_pos.x):
			continue
		var is_sel := int(src_cell) == _selected_source
		var ring_r := _hex_size * (0.66 if is_sel else 0.58)
		var ring_col := SELECTED_SOURCE_COLOR if is_sel else CANDIDATE_SOURCE_COLOR
		draw_arc(s_pos, ring_r, 0.0, TAU, 36, LINE_CASING, 4.4 if is_sel else 3.8, true)
		draw_arc(s_pos, ring_r, 0.0, TAU, 36, ring_col, 2.4 if is_sel else 2.0, true)
		if is_sel and _route.size() < 2:
			draw_circle(s_pos, 5.0, LINE_CASING)
			draw_circle(s_pos, 3.2, SELECTED_SOURCE_COLOR)

	if _selected_source >= 0 and not _candidate_sources.has(_selected_source):
		var sel_pos := _cell_world_pos(_selected_source, ref_x)
		if not is_nan(sel_pos.x):
			var r_sel := _hex_size * 0.66
			draw_arc(sel_pos, r_sel, 0.0, TAU, 36, LINE_CASING, 4.4, true)
			draw_arc(sel_pos, r_sel, 0.0, TAU, 36, SELECTED_SOURCE_COLOR, 2.4, true)

	if _route.size() < 2:
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
