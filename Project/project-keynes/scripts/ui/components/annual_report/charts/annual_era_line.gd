extends AnnualChartBase
class_name AnnualEraLine

## 时代长线：十一个文明阶段排成一条直线，当前时代是唯一一个朱红实心点。
## 这条线不承载数值，它承载"我们在哪里"——比一句"文明处于石器时代"更有位置感。

var _index := 0
var _names := PackedStringArray()


func set_data(index: int, names: PackedStringArray) -> bool:
	if names.is_empty():
		return false
	_index = clampi(index, 0, names.size() - 1)
	_names = names
	custom_minimum_size.y = 96.0
	_start_reveal()
	return true


func _draw() -> void:
	var w: float = size.x
	var count: int = _names.size()
	if count < 2:
		return
	var line_y: float = 40.0
	var pitch: float = w / float(count - 1)
	draw_line(Vector2(0.0, line_y), Vector2(w, line_y), Color(_ink.r, _ink.g, _ink.b, 0.24 * _grow), 1.0, true)
	for i in count:
		var x: float = pitch * float(i)
		if i < _index:
			draw_circle(Vector2(x, line_y), 2.6, Color(_ink.r, _ink.g, _ink.b, 0.62))
		elif i == _index:
			draw_circle(Vector2(x, line_y), 5.4, _accent)
			draw_line(Vector2(x, line_y - 14.0), Vector2(x, line_y - 8.0), _accent, 1.0, true)
		else:
			draw_arc(Vector2(x, line_y), 3.2, 0.0, TAU, 18, Color(_ink.r, _ink.g, _ink.b, 0.34), 1.0, true)
		if _grow > 0.6:
			var name: String = _names[i]
			var size_px := 13
			var width: float = _text_width(name, size_px, "label")
			var color: Color = _accent if i == _index else Color(_muted.r, _muted.g, _muted.b, 0.55 if i > _index else 0.85)
			_text(Vector2(clampf(x - width * 0.5, 0.0, maxf(0.0, w - width)), line_y + 22.0), name, size_px, color, "label")
	if _index < _names.size() and _grow > 0.6:
		var x: float = pitch * float(_index)
		var caption := "本年"
		var width: float = _text_width(caption, 13, "label")
		_text(Vector2(clampf(x - width * 0.5, 0.0, maxf(0.0, w - width)), line_y - 20.0), caption, 13, _accent, "label")
