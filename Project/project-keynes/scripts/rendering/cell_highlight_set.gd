# cell_highlight_set.gd
# 一组地块的轮廓绘制器（理念卡「命中在哪里」）。
#
# 与 cell_highlight.gd 的分工：
#   CellHighlight      —— 单选地块，玩家点哪块亮哪块，暖金 + 脉冲。
#   CellHighlightSet   —— 一张理念卡同时命中的 N 块地，朱红、无脉冲、可整个换掉。
# 两者挂在同一个 WorldRoot 下互不通信，所以「选中的地块落在命中集里」会同时
# 画出两层轮廓——这是有意的：那正是「我点的这块地被这张卡影响了」的表达。
#
# 为什么不复用 DataOverlayLayer：
#   overlay 是「整张图按一个模式着色」的持久图层，切换模式会挤掉玩家正在看的
#   资源/人口分布。命中高亮是**临时**的、由一次点击触发的、且必须能和任意
#   overlay 叠加。塞进 overlay 的 mode 枚举会把两件事绑死。
#
# 只画，不查地图。cell 索引 -> 世界坐标的换算留在调用方（它才知道相机位置
# 和环绕周期），这里拿到什么就画什么。多画一个格子比查错一格便宜。

class_name CellHighlightSet
extends Node2D

## 默认色对应 `IdeologyArt.VERMILION`（理念模块自己的朱红）。与选中高亮的
## 暖金形成对比，避免「哪块是我选的」和「哪块是卡命中的」混成一片。
@export var line_color: Color = Color(0.66, 0.15, 0.09, 0.95)
@export var line_width: float = 1.8
@export var fill_color: Color = Color(0.66, 0.15, 0.09, 0.13)

var _centers: PackedVector2Array = PackedVector2Array()
var _hex_size: float = 22.0
var _wrap_period_x: float = 0.0


## Replace the whole set. Empty input clears, which is what the caller wants on
## a card with no cell targets — no separate "hide" call to forget.
func set_cells(centers: PackedVector2Array, hex_size: float,
		wrap_period_x: float = 0.0) -> void:
	_hex_size = maxf(1.0, hex_size)
	_wrap_period_x = maxf(0.0, wrap_period_x)
	_centers = centers
	queue_redraw()


func clear() -> void:
	if _centers.is_empty():
		return
	_centers = PackedVector2Array()
	queue_redraw()


func cell_count() -> int:
	return _centers.size()


func _draw() -> void:
	if _centers.is_empty():
		return
	var pts := PackedVector2Array()
	for center in _centers:
		# A card can hit the same cell on both sides of a wrapped map, so every
		# centre is drawn three times like CellHighlight does. The clone is off
		# screen most of the time and costs six vertices.
		_draw_hex(center, pts)
		if _wrap_period_x > 0.0001:
			_draw_hex(center + Vector2(_wrap_period_x, 0.0), pts)
			_draw_hex(center - Vector2(_wrap_period_x, 0.0), pts)


func _draw_hex(center: Vector2, pts: PackedVector2Array) -> void:
	pts.clear()
	# pointy-top 六边形顶点，与 cell_highlight.gd 同约定：60°*i - 30°。
	for i in range(6):
		var ang: float = deg_to_rad(60.0 * float(i) - 30.0)
		pts.append(center + Vector2(cos(ang), sin(ang)) * _hex_size)
	draw_colored_polygon(pts, fill_color)
	pts.append(pts[0])
	draw_polyline(pts, Color(0.0, 0.0, 0.0, 0.44), line_width + 2.4, true)
	draw_polyline(pts, line_color, line_width, true)
