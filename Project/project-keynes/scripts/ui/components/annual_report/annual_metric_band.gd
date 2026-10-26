extends Control
class_name AnnualMetricBand

## 章节的关键数字带：两到四个巨数，共享一条基线。
## 旧版的统计行是「18px 标签 + 20px 数值，中间隔八百像素」，
## 数值完全不占主导；这里把数字推到 96px，标签降到 13px，一眼看到量级。
##
## 窄版心不再一列堆到底：一列四个数字要吃掉整屏，密度正是这样丢的。
## 这里改成两列网格，数字缩到 56px，四个数从 472px 压到 184px。

var _figures: Array = []
var _compact := false
var _hint := 0.0
var _accent: Color = UITokens.CHRONICLE_RED
var _ink: Color = UITokens.CHRONICLE_INK
var _muted: Color = UITokens.CHRONICLE_MUTED
var _brass: Color = UITokens.CHRONICLE_BRASS

const COMPACT_ROW := 92.0
const COMPACT_GAP := 14.0
const WIDE_HEIGHT := 136.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_compact(value: bool, width: float = 0.0) -> void:
	_compact = value
	_hint = width
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
		custom_minimum_size.y = COMPACT_ROW * float(_compact_rows())
	else:
		custom_minimum_size.y = WIDE_HEIGHT


func _compact_columns() -> int:
	# 版心 ≥600 时三列：六个数只占两行，比两列三行更省一屏。
	var columns: int = 3 if _hint >= 600.0 else 2
	return maxi(1, mini(columns, _figures.size()))


func _compact_rows() -> int:
	return int(ceil(float(_figures.size()) / float(_compact_columns())))


func _draw() -> void:
	if _figures.is_empty():
		return
	if _compact:
		var columns: int = _compact_columns()
		var cell: float = (size.x - COMPACT_GAP * float(columns - 1)) / float(columns)
		for i in _figures.size():
			var column: int = i % columns
			var row: int = i / columns
			_draw_item(_figures[i], Rect2(float(column) * (cell + COMPACT_GAP), COMPACT_ROW * float(row), cell, COMPACT_ROW), true)
		return
	var count: int = _figures.size()
	var gap: float = 28.0
	var item_width: float = (size.x - gap * float(count - 1)) / float(count)
	for i in count:
		_draw_item(_figures[i], Rect2(float(i) * (item_width + gap), 0.0, item_width, size.y))


func _draw_item(figure: Dictionary, rect: Rect2, compact: bool = false) -> void:
	var tone: String = String(figure.get("tone", "plain"))
	var color: Color = UITokens.CHRONICLE_PENCIL_RED if tone == "accent" else _ink
	var text: String = String(figure.get("text", "—"))
	var unit: String = String(figure.get("unit", ""))
	var label: String = String(figure.get("label", ""))

	_text(Vector2(rect.position.x, rect.position.y + 16.0), label, 13, _muted, "label")

	# 数字自适应：宁可缩小也不换行，因为换行会破坏整条基线。
	var desired := 56 if compact else 96
	var size_px := _fit_size(text, desired, rect.size.x - 4.0, "numeral")
	var baseline: float = rect.position.y + 18.0 + float(size_px) * 0.94
	# Hand-cut colored-paper swatches sit behind the large numerals. Their pale
	# offsets preserve the paper-cut silhouette without obscuring the values.
	var swatch := Rect2(rect.position + Vector2(0.0, 3.0),
		Vector2(minf(rect.size.x - 8.0, maxf(76.0, _text_width(text, size_px, "numeral"))),
			float(size_px) * 0.88))
	if compact:
		swatch.size.y = float(size_px) * 0.78
	var swatch_color: Color = (UITokens.CHRONICLE_PENCIL_GOLD if tone == "accent"
		else UITokens.CHRONICLE_PENCIL_BLUE)
	draw_colored_polygon(PackedVector2Array([
		swatch.position + Vector2(7.0, 0.0),
		Vector2(swatch.end.x - 4.0, swatch.position.y + 2.0),
		swatch.end - Vector2(0.0, 5.0),
		Vector2(swatch.position.x + 2.0, swatch.end.y),
	]), Color(swatch_color.r, swatch_color.g, swatch_color.b, 0.22))
	var hatch_x := swatch.position.x + 7.0
	while hatch_x < swatch.end.x - 3.0:
		draw_line(Vector2(hatch_x, swatch.position.y + 2.0),
			Vector2(maxf(swatch.position.x, hatch_x - 15.0), swatch.end.y - 2.0),
			Color(swatch_color.r, swatch_color.g, swatch_color.b, 0.14), 1.0, true)
		hatch_x += 11.0
	_text(Vector2(rect.position.x, baseline), text, size_px, color, "numeral")

	if not unit.is_empty():
		var width: float = _text_width(text, size_px, "numeral")
		_text(Vector2(rect.position.x + width + 6.0, baseline - float(size_px) * 0.08), unit, 15, _muted, "label")

	var delta: String = String(figure.get("delta", "—"))
	if delta != "—" and not delta.is_empty():
		var direction: int = int(figure.get("direction", 0))
		var delta_color: Color = (UITokens.CHRONICLE_PENCIL_GREEN if direction > 0
			else (UITokens.CHRONICLE_PENCIL_RED if direction < 0 else _muted))
		_text(Vector2(rect.position.x, baseline + (17.0 if compact else 22.0)), delta, 14 if compact else 15, delta_color, "label")


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
