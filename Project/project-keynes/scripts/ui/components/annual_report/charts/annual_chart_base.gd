extends DossierChart
class_name AnnualChartBase

## 纸本长卷图表的公共基类。
##
## 复用 DossierChart 的 `_grow/_blend` 两段动效与文字工具，但把配色与绘制语言
## 换成彩铅剪纸：粗黑轮廓、蜡笔颗粒、白纸留白和少量高饱和填色。图表仍是
## 数据标记而不是卡片，必须保持标签和轴线的可读性。

var _ink: Color = UITokens.CHRONICLE_INK
var _accent: Color = UITokens.CHRONICLE_RED
var _muted: Color = UITokens.CHRONICLE_MUTED
var _brass: Color = UITokens.CHRONICLE_BRASS
var _rule: Color = UITokens.CHRONICLE_RULE
var _reveal_enabled := true


func set_ink(primary: Color, accent: Color, muted: Color) -> void:
	_ink = primary
	_accent = accent
	_muted = muted
	_brass = accent.lerp(primary, 0.42)
	_rule = Color(primary.r, primary.g, primary.b, 0.16)
	queue_redraw()


## reduced_motion 时关掉生长动画，直接给终值。
func set_reveal_enabled(value: bool) -> void:
	_reveal_enabled = value
	if not value:
		_grow = 1.0
		_blend = 1.0
		queue_redraw()


func _start_reveal() -> void:
	if _reveal_enabled:
		_start_animation()
	else:
		_grow = 1.0
		_blend = 1.0
		queue_redraw()


func _afont(kind: String = "label") -> Font:
	return UITokens.annual_font(kind)


## 覆写 DossierChart 的字体工厂：本页只用纸本字阶，不接卷宗的 sans/serif 语义。
func _font(kind: String = "label") -> Font:
	return UITokens.annual_font(kind)


func _line(from: Vector2, to: Vector2, color: Color, width: float = 1.0) -> void:
	if from.distance_to(to) < 0.4:
		return
	draw_line(from, to, color, width + 1.4, true)
	draw_line(from, to, color.lightened(0.13), maxf(1.0, width * 0.52), true)


func _hairline(y: float, left: float, right: float, alpha: float = 0.09) -> void:
	var a := clampf(alpha + 0.035, 0.07, 0.22)
	draw_line(Vector2(left, y), Vector2(right, y), Color(_ink.r, _ink.g, _ink.b, a), 1.0, true)


func _baseline(y: float, left: float, right: float) -> void:
	var pencil := Color(_ink.r, _ink.g, _ink.b, 0.76)
	draw_line(Vector2(left, y), Vector2(right, y), pencil, 2.8, true)
	draw_line(Vector2(left + 1.0, y + 2.0), Vector2(right - 1.0, y + 2.0),
		Color(_ink.r, _ink.g, _ink.b, 0.11), 1.0, true)


func _caption(at: Vector2, text: String, color: Color = Color(0, 0, 0, 0), size_px: int = UITokens.CHRONICLE_LABEL) -> void:
	var tone := _muted if color.a == 0.0 else color
	_text(at, text, size_px, tone, "label")


func _figure(at: Vector2, text: String, size_px: int, color: Color) -> void:
	_text(at, text, size_px, color, "numeral")


func _right_text(right_x: float, baseline_y: float, text: String, size_px: int, color: Color, kind: String = "numeral") -> void:
	var width := _text_width(text, size_px, kind)
	_text(Vector2(right_x - width, baseline_y), text, size_px, color, kind)


func _poly(points: PackedVector2Array, color: Color) -> void:
	if points.size() < 3:
		return
	draw_colored_polygon(points, color)


## Pencil shading is deliberately sparse: it reads as crayon grain at UI scale
## without turning every chart into a noisy fill.
func _pencil_fill(rect: Rect2, color: Color, direction: int = 1, step: float = 9.0) -> void:
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	draw_rect(rect, Color(color.r, color.g, color.b, 0.18), true)
	var x := rect.position.x - rect.size.y
	while x < rect.end.x:
		var y0: float = rect.position.y
		var y1: float = rect.end.y
		var slope := 0.35 if direction >= 0 else -0.35
		var p0 := Vector2(maxf(rect.position.x, x), y0 if direction >= 0 else y1)
		var p1 := Vector2(minf(rect.end.x, x + rect.size.y * slope), y1 if direction >= 0 else y0)
		if p0.x < p1.x:
			draw_line(p0, p1, Color(color.r, color.g, color.b, 0.12), 1.0, true)
		x += step
	draw_rect(rect, Color(_ink.r, _ink.g, _ink.b, 0.36), false, 1.2)


func _sticker(rect: Rect2, fill: Color, stroke: Color) -> void:
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var cut := minf(5.0, rect.size.y * 0.28)
	var points := PackedVector2Array([
		rect.position + Vector2(cut * 0.35, 0.0),
		rect.position + Vector2(rect.size.x * 0.52, 0.8),
		rect.position + Vector2(rect.size.x - 0.7, cut * 0.2),
		rect.position + Vector2(rect.size.x - 1.2, rect.size.y - cut * 0.3),
		rect.position + Vector2(rect.size.x * 0.43, rect.size.y - 0.8),
		rect.position + Vector2(0.7, rect.size.y - cut * 0.18),
	])
	draw_colored_polygon(points, fill)
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, stroke, 2.2, true)
