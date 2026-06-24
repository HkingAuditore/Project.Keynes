# cell_highlight.gd
# 选中地块的轻量轮廓绘制器。
# 不持有任何数据，只在 set_cell() 时记录中心世界坐标 + hex_size，
# 然后在 _draw 里画 pointy-top 六边形的双色轮廓（外圈黑暗、内圈高亮）。
#
# 使用：挂在 WorldRoot 下，top_level=true，z_index 高于 hex_renderer。
# 由 main.gd 在选中 / 取消选中时调用 set_cell / clear。

class_name CellHighlight
extends Node2D

@export var line_color: Color = Color(1.0, 0.95, 0.4, 0.95)
@export var line_width: float = 2.5
@export var inner_color: Color = Color(0.0, 0.0, 0.0, 0.55)

var _center: Vector2 = Vector2.ZERO
var _hex_size: float = 22.0
var _wrap_period_x: float = 0.0
var _active: bool = false

func set_cell(cell: HexCell, hex_size: float) -> void:
	if cell == null:
		clear()
		return
	set_cell_display(cell, hex_size, HexUtils.cube_to_world(cell.q, cell.r, hex_size), 0.0)

func set_cell_display(cell: HexCell, hex_size: float, display_center: Vector2, wrap_period_x: float = 0.0) -> void:
	if cell == null:
		clear()
		return
	_hex_size = hex_size
	_center = display_center
	_wrap_period_x = maxf(0.0, wrap_period_x)
	_active = true
	queue_redraw()

func clear() -> void:
	_active = false
	queue_redraw()

func _draw() -> void:
	if not _active:
		return
	_draw_hex_outline(_center)
	if _wrap_period_x > 0.0001:
		_draw_hex_outline(_center + Vector2(_wrap_period_x, 0.0))
		_draw_hex_outline(_center - Vector2(_wrap_period_x, 0.0))

func _draw_hex_outline(center: Vector2) -> void:
	var pts := PackedVector2Array()
	# pointy-top 六边形顶点：角度从 -30° 起每 60° 一个
	for i in range(6):
		var ang: float = deg_to_rad(60.0 * float(i) - 30.0)
		pts.append(center + Vector2(cos(ang), sin(ang)) * _hex_size)
	pts.append(pts[0])
	# 外圈描黑加宽，给高亮轮廓做衬底
	draw_polyline(pts, inner_color, line_width + 2.0, true)
	draw_polyline(pts, line_color, line_width, true)
