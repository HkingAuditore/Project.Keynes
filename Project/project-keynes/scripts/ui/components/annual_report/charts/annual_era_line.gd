extends AnnualChartBase
class_name AnnualEraLine

## 时代长线：十一个文明阶段排成一条直线，当前时代是唯一一个朱红实心点。
## 这条线不承载数值，它承载"我们在哪里"——比一句"文明处于石器时代"更有位置感。

var _index := 0
var _names := PackedStringArray()


func set_data(index: int, names: PackedStringArray) -> bool:
	if names.size() < 2:
		return false
	_index = clampi(index, 0, names.size() - 1)
	_names = names
	custom_minimum_size.y = 112.0
	_start_reveal()
	return true


func _draw() -> void:
	var w: float = size.x
	var count: int = _names.size()
	if count < 2:
		return
	var line_y: float = 40.0
	var pitch: float = w / float(count - 1)
	draw_line(Vector2(0.0, line_y), Vector2(w, line_y), Color(_ink.r, _ink.g, _ink.b, 0.54 * _grow), 3.0, true)
	draw_line(Vector2(0.0, line_y + 2.2), Vector2(w, line_y + 2.2), Color(_ink.r, _ink.g, _ink.b, 0.12 * _grow), 1.0, true)
	var font := _font("label")
	var size_px := 13
	var current_name: String = _names[_index]
	var current_width: float = font.get_string_size(current_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x
	var current_center: float = clampf(pitch * float(_index), current_width * 0.5 + 4.0,
		w - current_width * 0.5 - 4.0)
	var label_top: float = line_y + 15.0
	var claimed: Array[Vector2] = []
	if _grow > 0.6:
		var current_rect := Rect2(current_center - current_width * 0.5 - 7.0,
			label_top - 2.0, current_width + 14.0, float(size_px) + 6.0)
		draw_colored_polygon(PackedVector2Array([
			current_rect.position + Vector2(3.0, 0.0),
			Vector2(current_rect.end.x, current_rect.position.y + 1.0),
			current_rect.end - Vector2(1.0, 2.0),
			Vector2(current_rect.position.x + 1.0, current_rect.end.y),
		]), Color(UITokens.CHRONICLE_PENCIL_GOLD.r, UITokens.CHRONICLE_PENCIL_GOLD.g,
			UITokens.CHRONICLE_PENCIL_GOLD.b, 0.30))
		_text(Vector2(current_center - current_width * 0.5, label_top + float(size_px)),
			current_name, size_px, UITokens.CHRONICLE_INK, "label")
		claimed.append(Vector2(current_rect.position.x, current_rect.end.x))
	for distance in range(1, mini(2, count) + 1):
		for direction in [-1, 1]:
			var neighbor: int = _index + direction * distance
			if neighbor < 0 or neighbor >= count:
				continue
			var name: String = _names[neighbor]
			var width: float = _text_width(name, size_px, "label")
			var center: float = clampf(pitch * float(neighbor), width * 0.5 + 4.0,
				w - width * 0.5 - 4.0)
			var left := center - width * 0.5 - 5.0
			var right := center + width * 0.5 + 5.0
			var overlaps := false
			for span in claimed:
				if right > span.x and left < span.y:
					overlaps = true
					break
			if overlaps:
				continue
			_text(Vector2(center - width * 0.5, label_top + float(size_px)), name,
				size_px, Color(_ink.r, _ink.g, _ink.b, 0.62), "label")
			claimed.append(Vector2(left, right))
	for i in count:
		var x: float = pitch * float(i)
		if i < _index:
			draw_circle(Vector2(x, line_y), 4.7, Color(_ink.r, _ink.g, _ink.b, 0.88))
			draw_circle(Vector2(x, line_y), 2.5, UITokens.CHRONICLE_PENCIL_BLUE)
		elif i == _index:
			draw_circle(Vector2(x, line_y), 9.0, Color(_ink.r, _ink.g, _ink.b, 0.9))
			draw_circle(Vector2(x, line_y), 6.4, UITokens.CHRONICLE_PENCIL_RED)
			draw_line(Vector2(x, line_y - 16.0), Vector2(x, line_y - 9.0), UITokens.CHRONICLE_PENCIL_RED, 2.5, true)
		else:
			draw_arc(Vector2(x, line_y), 4.0, 0.0, TAU, 18, Color(_ink.r, _ink.g, _ink.b, 0.48), 2.0, true)
	if _index < _names.size() and _grow > 0.6:
		var x: float = pitch * float(_index)
		var caption := "本年"
		var width: float = _text_width(caption, 13, "label")
		_text(Vector2(clampf(x - width * 0.5, 0.0, maxf(0.0, w - width)), line_y - 20.0), caption, 13, _accent, "label")
		var position_text := "%d / %d" % [_index + 1, count]
		var position_width: float = _text_width(position_text, 12, "label")
		_text(Vector2(w - position_width, 15.0), position_text, 12,
			Color(_ink.r, _ink.g, _ink.b, 0.58), "label")
