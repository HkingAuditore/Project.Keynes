extends Control
class_name AnnualLedger

## 细线账簿。
##
## 旧版每行是「标签左、数值右，中间隔六百到九百像素」，眼睛必须横穿整页才配得上一对数；
## 数值 20px 只比标签 18px 大一点，数据完全不占主导。
## 这里把当前值推到 24px 衬线、右对齐成列，上年与增减退到左侧 13px 小字，
## 行与行之间只用一条 alpha 0.10 的发丝线，不画竖线也不画表框。
##
## 首年没有上年数据时，整列「上年 / 增减」被删掉（show_previous = false），
## 而不是逐行重复"无可比数据"。

var _rows: Array = []
var _show_previous := true
var _ink: Color = UITokens.CHRONICLE_INK
var _muted: Color = UITokens.CHRONICLE_MUTED
var _accent: Color = UITokens.CHRONICLE_RED
var _brass: Color = UITokens.CHRONICLE_BRASS

const ROW_HEIGHT := 38.0
const HEADER_HEIGHT := 22.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_rows(rows: Array, show_previous: bool) -> void:
	_rows = rows
	_show_previous = show_previous
	custom_minimum_size.y = HEADER_HEIGHT + ROW_HEIGHT * float(maxi(rows.size(), 1))
	queue_redraw()


func _draw() -> void:
	if _rows.is_empty():
		return
	var w: float = size.x
	var value_right: float = w
	var delta_right: float = w - 150.0
	var previous_right: float = w - 330.0
	if not _show_previous:
		delta_right = w
		previous_right = w - 150.0

	# 表头只在有可比数据时出现，并且是一次性的列名，不是每行重复的句子。
	var header_y: float = 6.0
	_caption(Vector2(0.0, header_y + 8.0), "指标")
	if _show_previous:
		_right_text(previous_right, header_y + 8.0, "上年", 13, Color(_muted.r, _muted.g, _muted.b, 0.8))
		_right_text(delta_right, header_y + 8.0, "增减与幅度", 13, Color(_muted.r, _muted.g, _muted.b, 0.8))
	_right_text(value_right, header_y + 8.0, "本年", 13, Color(_muted.r, _muted.g, _muted.b, 0.8))

	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var top: float = HEADER_HEIGHT + ROW_HEIGHT * float(i)
		var baseline: float = top + 22.0
		_text(Vector2(0.0, baseline), String(row.get("label", "")), 17, _ink, "body")
		var note: String = String(row.get("note", ""))
		if not note.is_empty():
			_caption(Vector2(0.0, baseline + 13.0), note)

		var current: String = String(row.get("current", "—"))
		var size_px := 24
		var width: float = _text_width(current, size_px, "numeral")
		if width > 150.0:
			size_px = maxi(15, int(float(size_px) * 150.0 / width))
		var current_color: Color = _ink
		var unit: String = String(row.get("unit", ""))
		if unit == "%":
			current_color = _ink
		_right_text(value_right, baseline, current, size_px, current_color)

		if _show_previous:
			var previous: String = String(row.get("previous", "—"))
			_right_text(previous_right, baseline - 1.0, previous, 15, Color(_muted.r, _muted.g, _muted.b, 0.85), "body")
			var delta: String = String(row.get("delta", "—"))
			var rate: String = String(row.get("rate", ""))
			if delta == "—" or delta.is_empty():
				_right_text(delta_right, baseline - 1.0, "—", 15, Color(_muted.r, _muted.g, _muted.b, 0.55), "body")
			else:
				var direction: int = int(row.get("direction", 0))
				var tone: Color = _brass if direction > 0 else (_accent if direction < 0 else _muted)
				_right_text(delta_right, baseline - 1.0, delta, 15, tone, "body")
				if not rate.is_empty() and rate != "无可比数据":
					_right_text(delta_right, baseline + 12.0, rate, 12, Color(tone.r, tone.g, tone.b, 0.8))

		# Alternating paper bands plus an uneven graphite stroke replace the
		# hairline printer rule that made the old report read as a ledger.
		if i % 2 == 1:
			draw_rect(Rect2(0.0, top, w, ROW_HEIGHT - 1.0),
				Color(UITokens.CHRONICLE_PENCIL_BLUE.r, UITokens.CHRONICLE_PENCIL_BLUE.g,
					UITokens.CHRONICLE_PENCIL_BLUE.b, 0.045), true)
		draw_line(Vector2(0.0, top + ROW_HEIGHT - 1.0), Vector2(w * 0.97, top + ROW_HEIGHT - 1.0),
			Color(_ink.r, _ink.g, _ink.b, 0.25), 1.4, true)
		draw_line(Vector2(2.0, top + ROW_HEIGHT + 0.8), Vector2(w * 0.94, top + ROW_HEIGHT + 0.8),
			Color(_ink.r, _ink.g, _ink.b, 0.045), 1.0, true)


func _text(at: Vector2, text: String, size_px: int, color: Color, kind: String) -> void:
	if text.is_empty():
		return
	draw_string(UITokens.annual_font(kind), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, color)


func _caption(at: Vector2, text: String) -> void:
	_text(at, text, 13, _muted, "label")


func _right_text(right_x: float, baseline_y: float, text: String, size_px: int, color: Color, kind: String = "numeral") -> void:
	if text.is_empty():
		return
	var width: float = _text_width(text, size_px, kind)
	_text(Vector2(right_x - width, baseline_y), text, size_px, color, kind)


func _text_width(text: String, size_px: int, kind: String) -> float:
	return UITokens.annual_font(kind).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x
