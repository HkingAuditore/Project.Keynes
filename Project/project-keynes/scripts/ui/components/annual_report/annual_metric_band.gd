extends Control
class_name AnnualMetricBand

## 章节的关键数字带：两到四个巨数，共享一条基线。
## 旧版的统计行是「18px 标签 + 20px 数值，中间隔八百像素」，
## 数值完全不占主导；这里把数字推到 96px，标签降到 13px，一眼看到量级。

var _figures: Array = []
var _compact := false
var _accent: Color = UITokens.CHRONICLE_RED
var _ink: Color = UITokens.CHRONICLE_INK
var _muted: Color = UITokens.CHRONICLE_MUTED
var _brass: Color = UITokens.CHRONICLE_BRASS


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_compact(value: bool) -> void:
	_compact = value
	_refresh_height()
	queue_redraw()


func set_figures(figures: Array) -> void:
	_figures = figures
	_refresh_height()
	queue_redraw()


func _refresh_height() -> void:
	if _figures.is_empty():
		custom_minimum_size.y = 0.0
	elif _compact:
		custom_minimum_size.y = 118.0 * float(_figures.size())
	else:
		custom_minimum_size.y = 150.0


func _draw() -> void:
	if _figures.is_empty():
		return
	if _compact:
		for i in _figures.size():
			_draw_item(_figures[i], Rect2(0.0, 118.0 * float(i), size.x, 118.0))
		return
	var count: int = _figures.size()
	var gap: float = 28.0
	var item_width: float = (size.x - gap * float(count - 1)) / float(count)
	for i in count:
		_draw_item(_figures[i], Rect2(float(i) * (item_width + gap), 0.0, item_width, size.y))


func _draw_item(figure: Dictionary, rect: Rect2) -> void:
	var tone: String = String(figure.get("tone", "plain"))
	var color: Color = _accent if tone == "accent" else _ink
	var text: String = String(figure.get("text", "—"))
	var unit: String = String(figure.get("unit", ""))
	var label: String = String(figure.get("label", ""))

	_text(Vector2(rect.position.x, rect.position.y + 16.0), label, 13, _muted, "label")

	# 数字自适应：宁可缩小也不换行，因为换行会破坏整条基线。
	var desired := 96 if not _compact else 72
	var size_px := _fit_size(text, desired, rect.size.x - 4.0, "numeral")
	var baseline: float = rect.position.y + 18.0 + float(size_px) * 0.94
	_text(Vector2(rect.position.x, baseline), text, size_px, color, "numeral")

	if not unit.is_empty():
		var width: float = _text_width(text, size_px, "numeral")
		_text(Vector2(rect.position.x + width + 6.0, baseline - float(size_px) * 0.08), unit, 15, _muted, "label")

	var delta: String = String(figure.get("delta", "—"))
	if delta != "—" and not delta.is_empty():
		var direction: int = int(figure.get("direction", 0))
		var delta_color: Color = _brass if direction > 0 else (_accent if direction < 0 else _muted)
		_text(Vector2(rect.position.x, baseline + 22.0), delta, 15, delta_color, "label")


func _text(at: Vector2, text: String, size_px: int, color: Color, kind: String) -> void:
	if text.is_empty():
		return
	draw_string(UITokens.annual_font(kind), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, color)


func _text_width(text: String, size_px: int, kind: String) -> float:
	return UITokens.annual_font(kind).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x


func _fit_size(text: String, desired: int, max_width: float, kind: String) -> int:
	if max_width <= 0.0:
		return desired
	var width: float = _text_width(text, desired, kind)
	if width <= max_width:
		return desired
	return maxi(24, int(float(desired) * max_width / maxf(width, 1.0)))
