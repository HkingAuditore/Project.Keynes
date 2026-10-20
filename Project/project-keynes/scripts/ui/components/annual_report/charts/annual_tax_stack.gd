extends AnnualChartBase
class_name AnnualTaxStack

## 税种构成带：一条 26px 的连续色带，段间留 2px 纸缝。
## 这是数据标记，不是容器——所以没有圆角、没有描边、没有底色轨道。
## 占比小于 2% 的段不标字，避免标签互相压住。

var _parts: Array = []
var _total := 0.0

const SEGMENT_HEIGHT := 26.0


func set_data(parts: Array) -> bool:
	if parts.is_empty():
		return false
	_parts = parts
	_total = 0.0
	for part in parts:
		_total += float(part.get("value", 0.0))
	if _total <= 0.0:
		return false
	custom_minimum_size.y = 108.0
	_start_reveal()
	return true


func _draw() -> void:
	if _parts.is_empty() or _total <= 0.0:
		return
	var w: float = size.x
	var y: float = 34.0
	var ramp := [
		Color(_accent.r, _accent.g, _accent.b, 0.86),
		Color(_brass.r, _brass.g, _brass.b, 0.80),
		Color(_ink.r, _ink.g, _ink.b, 0.62),
		Color(_muted.r, _muted.g, _muted.b, 0.52),
		Color(_ink.r, _ink.g, _ink.b, 0.30),
		Color(_muted.r, _muted.g, _muted.b, 0.28),
	]
	var cursor: float = 0.0
	var label_index := 0
	for i in _parts.size():
		var part: Dictionary = _parts[i]
		var share: float = float(part.get("value", 0.0)) / _total
		var length: float = w * share
		var drawn: float = length * _grow
		if drawn > 0.4:
			draw_rect(Rect2(cursor, y, maxf(1.0, drawn - 2.0), SEGMENT_HEIGHT), ramp[i % ramp.size()], true)
		if share >= 0.02 and _grow > 0.75:
			var center: float = cursor + length * 0.5
			var above: bool = label_index % 2 == 0
			var label_y: float = y - 12.0 if above else y + SEGMENT_HEIGHT + 24.0
			draw_line(Vector2(center, y + (0.0 if above else SEGMENT_HEIGHT)), Vector2(center, label_y + (6.0 if above else -12.0)), Color(_ink.r, _ink.g, _ink.b, 0.22), 1.0, true)
			var name: String = String(part.get("label", ""))
			var percent := "%.0f%%" % (share * 100.0)
			var text := name + " " + percent
			var width: float = _text_width(text, 13, "label")
			_text(Vector2(clampf(center - width * 0.5, 0.0, maxf(0.0, w - width)), label_y), text, 13, _muted, "label")
			label_index += 1
		cursor += length
	_caption(Vector2(0.0, 14.0), "五项税收合计 " + UITokens.format_compact_number_cn(_total))
