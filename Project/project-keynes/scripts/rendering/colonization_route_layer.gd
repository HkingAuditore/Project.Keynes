extends Node2D
class_name ColonizationRouteLayer

const LINE_COLOR := Color(0.86, 0.64, 0.30, 0.96)
const LINE_CASING := Color(0.08, 0.055, 0.03, 0.90)
const TARGET_COLOR := Color(0.93, 0.76, 0.42, 1.0)
const CANDIDATE_SOURCE_COLOR := Color(0.26, 0.64, 0.52, 0.92)
const SELECTED_SOURCE_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const DUST: Texture2D = preload("res://assets/vfx/settlement_dust.png")

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
var _phase := 0.0
var _draw_elapsed := 0.0
var _display_cost := -1.0
var _is_quote := false
var _points := PackedVector2Array()
var _reduced_motion := false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func set_context(map: MapData, clock: WorldClock, hex_size: float,
		wrap_period: float) -> void:
	_map = map
	_clock = clock
	_hex_size = hex_size
	_wrap_period = wrap_period
	_rebuild_points()
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
	_is_quote = true
	_display_cost = 0.0
	_route = detail.get("route_cells", PackedInt32Array())
	_cumulative = detail.get("cumulative_costs", PackedInt32Array())
	_departure_day = _clock.day_index() if _clock != null else 0
	_due_day = _departure_day + int(detail.get("travel_days", 1))
	_route_cost = int(detail.get("route_cost", 0))
	_speed = maxi(1, ceili(float(_route_cost) / maxi(1, _due_day - _departure_day)))
	_state = 1
	_rebuild_points()
	_sync_visibility()
	queue_redraw()


func show_expedition(snapshot: Dictionary) -> void:
	_is_quote = false
	var next_route: PackedInt32Array = snapshot.get("route_cells", PackedInt32Array())
	if _route != next_route:
		_display_cost = -1.0
	_route = next_route
	_cumulative = snapshot.get("cumulative_costs", PackedInt32Array())
	_departure_day = int(snapshot.get("departure_day", 0))
	_due_day = int(snapshot.get("due_day", _departure_day))
	_route_cost = int(snapshot.get("route_cost", 0))
	_speed = maxi(1, int(snapshot.get("speed", 1)))
	_state = int(snapshot.get("state", 1))
	_rebuild_points()
	if _display_cost < 0.0 or UIAnimation.reduced_motion():
		_display_cost = float(_progress_cost())
	_sync_visibility()
	queue_redraw()


func clear_route() -> void:
	_route.clear()
	_cumulative.clear()
	_points.clear()
	_display_cost = -1.0
	_sync_visibility()
	queue_redraw()


func _sync_visibility() -> void:
	visible = not _route.is_empty() or not _candidate_sources.is_empty() \
		or _selected_source >= 0 or _selected_target >= 0


func _process(delta: float) -> void:
	if not visible:
		return
	_reduced_motion = UIAnimation.reduced_motion()
	_phase += delta
	_draw_elapsed += delta
	var day := _clock.day_index() if _clock != null else 0
	if not _is_quote:
		_display_cost = lerpf(maxf(0.0, _display_cost), float(_progress_cost()),
			1.0 if _reduced_motion else minf(1.0, delta * 7.0))
	if day != _last_day or (not _reduced_motion and _draw_elapsed >= 1.0 / 30.0):
		_last_day = day
		_draw_elapsed = 0.0
		queue_redraw()


func _rebuild_points() -> void:
	_points.clear()
	var camera := get_viewport().get_camera_2d() if is_inside_tree() else null
	var previous_x: float = camera.global_position.x if camera != null else NAN
	for cell_idx in _route:
		var point := _cell_world_pos(int(cell_idx), previous_x)
		if is_nan(point.x):
			_points.clear()
			return
		_points.append(point)
		previous_x = point.x


func _cell_world_pos(cell_idx: int, ref_x: float = NAN) -> Vector2:
	if _map == null or cell_idx < 0:
		return Vector2(NAN, NAN)
	var cell = _map.cell_at(cell_idx)
	if cell == null:
		return Vector2(NAN, NAN)
	var point := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	if is_nan(ref_x) and is_inside_tree():
		var camera := get_viewport().get_camera_2d()
		if camera != null:
			ref_x = camera.global_position.x
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
	var points := _points
	if points.size() < 2:
		return
	# Rebase the whole continuous route to the camera's cylindrical world copy.
	var camera := get_viewport().get_camera_2d()
	var shift := Vector2.ZERO
	var unit := 1.0 / maxf(camera.zoom.x, 0.01) if camera != null else 1.0
	if camera != null:
		shift = HexUtils.nearest_display_world(points[0], camera.global_position.x,
			_wrap_period) - points[0]
	draw_set_transform(shift)
	draw_polyline(points, Color(LINE_COLOR, 0.13), 10.0 * unit, true)
	draw_polyline(points, LINE_CASING, 5.0 * unit, true)
	draw_polyline(points, Color(LINE_COLOR, 0.7), 2.0 * unit, true)
	# Moving route beads convey the direction of travel, even between game days.
	var phase := 0.0 if _reduced_motion else fmod(_phase * 0.45, 1.0)
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var direction := (b - a).normalized()
		if _state == 3:
			direction = -direction
		var bead := a.lerp(b, 1.0 - phase if _state == 3 else phase)
		draw_line(bead - direction * 3.0 * unit, bead + direction * 2.0 * unit,
			UITokens.MAP_ACTIVITY_GOLD, 2.0 * unit, true)
	draw_circle(points[0], 6.5 * unit, LINE_CASING)
	draw_circle(points[0], 4.0 * unit, LINE_COLOR)
	draw_circle(points[-1], 8.0 * unit, LINE_CASING)
	draw_circle(points[-1], 5.0 * unit, TARGET_COLOR)
	var marker := _point_at_cost(points, 0.0 if _is_quote else _display_cost)
	if not _is_quote and not _reduced_motion:
		var behind := _point_at_cost(points, clampf(_display_cost + (0.25 if _state == 3 else -0.25),
			0.0, float(_route_cost)))
		var direction := (marker - behind).normalized()
		for i in range(3):
			var life := fmod(_phase * 0.9 + float(i) / 3.0, 1.0)
			var size := lerpf(10.0, 26.0, life) * unit
			var center := marker - direction * life * 26.0 * unit
			draw_texture_rect(DUST, Rect2(center - Vector2.ONE * size * 0.5, Vector2.ONE * size),
				false, Color(1.0, 0.86, 0.58, (1.0 - life) * 0.28))
	var pulse := 0.5 if _reduced_motion else (sin(_phase * 3.5) * 0.5 + 0.5)
	draw_circle(marker, (10.0 + pulse * 2.0) * unit, Color(LINE_COLOR, 0.12 + pulse * 0.06))
	draw_circle(marker, 7.0 * unit, LINE_CASING)
	draw_circle(marker, 4.5 * unit, UITokens.MAP_ACTIVITY_GOLD)
	if not _is_quote:
		# Reuse the atlas territory icon as the expedition's raised standard.
		draw_line(marker, marker + Vector2(0, -15) * unit, LINE_CASING, 3.0 * unit, true)
		draw_set_transform(marker + shift + Vector2(-1.0, -15.0) * unit, 0.0, Vector2.ONE * unit)
		IconCatalog.draw_icon(self, &"map.expedition", Rect2(-8.0, -16.0, 24.0, 24.0))
	draw_set_transform(Vector2.ZERO)


func _progress_cost() -> int:
	var day := _clock.day_index() if _clock != null else _departure_day
	if _state == 3:
		return clampi(maxi(0, _due_day - day) * _speed,
			0, _route_cost)
	return clampi(maxi(0, day - _departure_day) * _speed, 0, _route_cost)


func _point_at_cost(points: PackedVector2Array, cost: float) -> Vector2:
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
