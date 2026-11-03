extends Node2D
class_name MilitaryRouteLayer

## z=11 行军路线层：选中部队的去程 / 回程路径，以及「下一步」预览。
##
## 复用 ColonizationRouteLayer 的方法：`_draw()` 直接画折线，wrap 地图上把整条
## 路线重基到相机最近的副本；路线 beads 沿路径流动表示行进方向；终点画目标环。
## 与开拓路线不同的是：
##   - 颜色是阵营色而不是开拓金，避免和开拓计划混淆；
##   - 用虚线（dash）表达「计划路线」而不是物流实线；
##   - 移动标记是纸片菱形而不是标准旗。
##
## 数据来源（两条路都走同一入口）：
##   show_route(route_cells, departure_day, due_day) —— 部队任务的目标格路径
##   show_preview(route_cells, cumulative, days)    —— preview_military_path 的暂存预览
## 路径缓存由调用方（军事面板 / 命令预览）持有，本层只负责画，不发起查询。

const LINE_COLOR := Color(0.86, 0.66, 0.34, 0.95)
const LINE_CASING := Color(0.09, 0.07, 0.04, 0.88)
const TARGET_COLOR := Color(0.97, 0.86, 0.56, 1.0)
const PREVIEW_COLOR := Color(0.68, 0.80, 0.92, 0.92)
const DUST: Texture2D = preload("res://assets/vfx/settlement_dust.png")

var _map
var _clock: WorldClock
var _hex_size := 22.0
var _wrap := 0.0

var _route := PackedInt32Array()
var _cumulative := PackedInt32Array()
var _departure_day := 0
var _due_day := 0
var _is_preview := false
var _last_day := -1
var _phase := 0.0
var _draw_elapsed := 0.0
var _display_day := -1.0
var _points := PackedVector2Array()
var _reduced_motion := false
var _player_slot := -1
var _enabled := true


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	set_process(true)


func configure(map, clock: WorldClock, hex_size: float, wrap_period_x: float) -> void:
	_map = map
	_clock = clock
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	_rebuild_points()
	_sync_visibility()


func set_player_slot(slot: int) -> void:
	_player_slot = slot


func set_enabled(enabled: bool) -> void:
	if _enabled == enabled:
		return
	_enabled = enabled
	_sync_visibility()


## 部队任务路径（实线金色 + 移动标记）。days 为预计到达天数。
func show_route(route_cells: PackedInt32Array, departure_day: int, due_day: int) -> void:
	_is_preview = false
	_route = route_cells
	_cumulative = PackedInt32Array()
	_departure_day = departure_day
	_due_day = maxi(due_day, departure_day)
	_rebuild_points()
	_sync_visibility()


## 路径预览（preview_military_path 的结果）：虚线冷色，不画移动标记。
func show_preview(route_cells: PackedInt32Array, cumulative_costs: PackedInt32Array,
		travel_days: int) -> void:
	_is_preview = true
	_route = route_cells
	_cumulative = cumulative_costs
	_departure_day = _clock.day_index() if _clock != null else 0
	_due_day = _departure_day + maxi(1, travel_days)
	_rebuild_points()
	_sync_visibility()


func clear_route() -> void:
	_route = PackedInt32Array()
	_cumulative = PackedInt32Array()
	_points = PackedVector2Array()
	_sync_visibility()


func _sync_visibility() -> void:
	visible = _enabled and _route.size() >= 2
	queue_redraw()


func _rebuild_points() -> void:
	_points.clear()
	if _map == null:
		return
	var ref_x := _camera_x()
	var previous_x := ref_x
	for cell_idx in _route:
		var point := _cell_world_pos(int(cell_idx), previous_x)
		if is_nan(point.x):
			_points.clear()
			return
		_points.append(point)
		previous_x = point.x


func _camera_x() -> float:
	if is_inside_tree():
		var camera := get_viewport().get_camera_2d()
		if camera != null:
			return camera.global_position.x
	return NAN


func _cell_world_pos(cell_idx: int, ref_x: float = NAN) -> Vector2:
	if _map == null or cell_idx < 0:
		return Vector2(NAN, NAN)
	var cell = _map.cell_at(cell_idx)
	if cell == null:
		return Vector2(NAN, NAN)
	var point := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	if is_nan(ref_x):
		ref_x = _camera_x()
	if not is_nan(ref_x) and _wrap > 0.0:
		point = HexUtils.nearest_display_world(point, ref_x, _wrap)
	return point


func _travel_day() -> float:
	if _clock == null:
		return float(_departure_day)
	return float(_clock.day_index())


func _process(delta: float) -> void:
	if not visible:
		return
	_reduced_motion = UIAnimation.reduced_motion()
	_phase += delta
	_draw_elapsed += delta
	var day := _travel_day()
	if not _reduced_motion:
		_display_day = lerpf(maxf(day, _display_day), day, minf(1.0, delta * 6.0))
	else:
		_display_day = day
	if day != _last_day or (not _reduced_motion and _draw_elapsed >= 1.0 / 30.0):
		_last_day = int(day)
		_draw_elapsed = 0.0
		queue_redraw()


func _draw() -> void:
	if _map == null or _points.size() < 2:
		return
	var camera := get_viewport().get_camera_2d() if is_inside_tree() else null
	var unit := 1.0 / maxf(camera.zoom.x, 0.01) if camera != null else 1.0
	var shift := Vector2.ZERO
	if camera != null:
		shift = HexUtils.nearest_display_world(_points[0], camera.global_position.x,
			_wrap) - _points[0]
	draw_set_transform(shift)

	var main := PREVIEW_COLOR if _is_preview else LINE_COLOR
	# 两遍描线：投影 + 主题色；预览用虚线，任务路径用实线。
	draw_polyline(_points, Color(LINE_CASING, 0.55), 4.4 * unit, true)
	if _is_preview:
		_draw_dashed(_points, main, 2.0 * unit, 7.0 * unit, 5.0 * unit)
	else:
		draw_polyline(_points, main, 2.2 * unit, true)

	# 行进 beads：沿路径移动的短线，表示方向。
	if not _is_preview:
		var phase := 0.0 if _reduced_motion else fmod(_phase * 0.6, 1.0)
		for i in range(1, _points.size()):
			var a := _points[i - 1]
			var b := _points[i]
			var direction := (b - a).normalized()
			var bead := a.lerp(b, phase)
			draw_line(bead - direction * 2.6 * unit, bead + direction * 2.0 * unit,
				UITokens.MAP_ACTIVITY_GOLD, 2.0 * unit, true)

	# 起点：纸片菱形（当前所在地）。
	var start := _points[0]
	var r := 5.0 * unit
	var diamond := PackedVector2Array([
		start + Vector2(0.0, -r), start + Vector2(r * 0.8, 0.0),
		start + Vector2(0.0, r), start + Vector2(-r * 0.8, 0.0),
	])
	draw_colored_polygon(diamond, LINE_CASING)
	draw_polyline(_closing(diamond), main, 1.6 * unit, true)

	# 终点：目标环 + 若为预览则画一个淡淡的准星。
	var target := _points[-1]
	var rr := _hex_size * 0.66
	draw_arc(target, rr, 0.0, TAU, 36, LINE_CASING, 4.2 * unit, true)
	draw_arc(target, rr, 0.0, TAU, 36,
		TARGET_COLOR if not _is_preview else PREVIEW_COLOR, 2.2 * unit, true)
	if _is_preview:
		draw_line(target + Vector2(-rr * 0.45, 0.0), target + Vector2(rr * 0.45, 0.0),
			PREVIEW_COLOR, 1.4 * unit, true)
		draw_line(target + Vector2(0.0, -rr * 0.45), target + Vector2(0.0, rr * 0.45),
			PREVIEW_COLOR, 1.4 * unit, true)
	else:
		# 行军标记：当前预计位置（按日推进），带一点扬尘。
		var total := maxi(1, _due_day - _departure_day)
		var t := clampf((_display_day - float(_departure_day)) / float(total), 0.0, 1.0)
		if _cumulative.size() == _points.size() and _cumulative.size() > 1:
			var cost := int(float(_cumulative[-1]) * t)
			var marker := _point_at_cost(_points, float(cost))
			var pulse := 0.5 if _reduced_motion else (sin(_phase * 3.5) * 0.5 + 0.5)
			draw_circle(marker, (8.0 + pulse * 2.0) * unit, Color(main, 0.14))
			draw_circle(marker, 5.0 * unit, LINE_CASING)
			draw_circle(marker, 3.2 * unit, UITokens.MAP_ACTIVITY_GOLD)
			if not _reduced_motion:
				for i in 3:
					var life := fmod(_phase * 0.9 + float(i) / 3.0, 1.0)
					var size := lerpf(9.0, 22.0, life) * unit
					draw_texture_rect(DUST, Rect2(marker - Vector2.ONE * size * 0.5,
						Vector2.ONE * size), false,
						Color(1.0, 0.86, 0.58, (1.0 - life) * 0.22))
	draw_set_transform(Vector2.ZERO)


func _closing(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out


func _draw_dashed(points: PackedVector2Array, color: Color, width: float,
		dash: float, gap: float) -> void:
	var period := maxf(dash + gap, 0.5)
	var travelled := 0.0
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		var direction := (b - a) / seg
		var pos := 0.0
		while pos < seg:
			var phase := fmod(travelled + pos, period)
			if phase < dash:
				var start := a + direction * pos
				var end := a + direction * minf(seg, pos + (dash - phase))
				draw_line(start, end, color, width, true)
			pos += maxf(period - phase, 0.5)
		travelled += seg


func _point_at_cost(points: PackedVector2Array, cost: float) -> Vector2:
	if _cumulative.size() != points.size() or points.is_empty():
		return points[0]
	for index in range(1, _cumulative.size()):
		if cost > int(_cumulative[index]):
			continue
		var low := int(_cumulative[index - 1])
		var high := int(_cumulative[index])
		var t := float(cost - low) / float(maxi(1, high - low))
		return points[index - 1].lerp(points[index], clampf(t, 0.0, 1.0))
	return points[-1]


func debug_snapshot() -> Dictionary:
	return {"visible": visible, "cells": _route.size(), "preview": _is_preview,
		"departure_day": _departure_day, "due_day": _due_day}
