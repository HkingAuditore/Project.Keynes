extends AnnualChartBase
class_name AnnualTierStairs

## 聚落等级的七级阶梯。
## 位置编码"等级高低"（越往右越高），长度编码"该级聚落数量"，
## 于是既能看出城市体系的形状，也能看出人口压在哪一级。

var _values := PackedFloat64Array()
var _previous := PackedFloat64Array()
var _names := PackedStringArray()


func set_data(values: PackedFloat64Array, previous: PackedFloat64Array, names: PackedStringArray) -> bool:
	if values.size() < 2:
		return false
	_values = values
	_previous = previous
	_names = names
	custom_minimum_size.y = 230.0
	_start_reveal()
	return true


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var levels: int = mini(7, _values.size() - 1) + 1
	if levels < 2:
		return
	var slot: float = w / float(levels - 1)
	var base_y: float = h - 34.0
	var rise: float = minf(22.0, (base_y - 48.0) / float(levels - 1))
	var max_count: float = 1.0
	for i in range(1, levels):
		max_count = maxf(max_count, _values[i])

	_baseline(base_y, 0.0, w)
	var prev_point := Vector2.ZERO
	for i in range(1, levels):
		var slot_left: float = slot * float(i - 1)
		var y: float = base_y - rise * float(i)
		var count: float = _values[i]
		var length: float = (slot - 18.0) * clampf(count / max_count, 0.0, 1.0) * _grow
		if length > 0.6:
			draw_line(Vector2(slot_left + 9.0, y), Vector2(slot_left + 9.0 + length, y), _accent, 4.0, true)
			if count > 0:
				_caption(Vector2(slot_left + 9.0, y - 9.0), "%d" % int(count))
		else:
			draw_line(Vector2(slot_left + 9.0, y), Vector2(slot_left + 9.0 + 26.0, y), Color(_ink.r, _ink.g, _ink.b, 0.14), 1.0, true)
		# 上一年的数量用铜金短标线挂在同一踏面下方
		if i < _previous.size() and _previous[i] > 0.0:
			var prior: float = (slot - 18.0) * clampf(_previous[i] / max_count, 0.0, 1.0)
			draw_line(Vector2(slot_left + 9.0 + prior, y + 5.0), Vector2(slot_left + 9.0 + prior, y + 10.0), Color(_brass.r, _brass.g, _brass.b, 0.9), 1.0, true)
		# 竖直踏板把台阶连起来
		if i > 1:
			draw_line(Vector2(slot_left + 9.0, prev_point.y), Vector2(slot_left + 9.0, y), Color(_ink.r, _ink.g, _ink.b, 0.22), 1.0, true)
		prev_point = Vector2(slot_left + 9.0, y)
		var name: String = _names[i] if i < _names.size() else "L%d" % i
		var width: float = _text_width(name, 13, "label")
		_text(Vector2(slot_left + 9.0 + (slot - 18.0) * 0.5 - width * 0.5, base_y + 20.0), name, 13, _muted, "label")

	if not _previous.is_empty():
		_caption(Vector2(0.0, 14.0), "实心为本年末，铜色小刻度为上年")
