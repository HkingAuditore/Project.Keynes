extends DossierChart
class_name AnnualChartBase

## 纸本长卷图表的公共基类。
##
## 复用 DossierChart 的 `_grow/_blend` 两段动效与文字工具，但把配色与绘制语言
## 换成印刷语言：不画外框、不画背景、不画竖网格，只允许一条基线加至多三条
## alpha ≤ 0.10 的发丝线。任何"卡片感"都会破坏整页的纸面。

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
	draw_line(from, to, color, width, true)


func _hairline(y: float, left: float, right: float, alpha: float = 0.09) -> void:
	draw_line(Vector2(left, y), Vector2(right, y), Color(_ink.r, _ink.g, _ink.b, alpha), 1.0, true)


func _baseline(y: float, left: float, right: float) -> void:
	draw_line(Vector2(left, y), Vector2(right, y), Color(_ink.r, _ink.g, _ink.b, 0.42), 1.0, true)


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
