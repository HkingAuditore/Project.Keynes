extends AnnualChartBase
class_name AnnualRadarDims

## 八维满意度雷达。
##
## 没有复用 dossier_radar_chart：那个组件把卷宗墨色写死、字号 11/12px、
## 尺寸按 168px 侧栏设计，放大到跨栏会散架。这里重画一版：
## 网点只保留四个同心环与八根辐条（属于数据图形，不是"框"），
## 标签 15px，直径跟着栏宽走。

var _names := PackedStringArray()
var _values := PackedFloat64Array()
var _previous := PackedFloat64Array()


func set_data(names: PackedStringArray, values: PackedFloat64Array, previous: PackedFloat64Array = PackedFloat64Array()) -> bool:
	if names.size() < 3 or values.size() < 3:
		return false
	_names = names
	_values = values
	_previous = previous
	_start_reveal()
	return true


func _draw() -> void:
	var count: int = mini(_names.size(), _values.size())
	if count < 3:
		return
	var center := size * 0.5
	var radius: float = maxf(40.0, minf(size.x * 0.5 - 92.0, size.y * 0.5 - 34.0))
	for ring in range(1, 5):
		var points := _polygon(center, radius * float(ring) / 4.0, PackedFloat64Array(), count, 1.0)
		points.append(points[0])
		draw_polyline(points, Color(_ink.r, _ink.g, _ink.b, 0.10 if ring < 4 else 0.20), 1.0, true)
	for i in count:
		var angle := -PI * 0.5 + TAU * float(i) / float(count)
		draw_line(center, center + Vector2(cos(angle), sin(angle)) * radius, Color(_ink.r, _ink.g, _ink.b, 0.12), 1.0, true)

	if _previous.size() == count:
		var prior := _polygon(center, radius, _previous, count, 1.0)
		for i in count:
			var next: int = (i + 1) % count
			if _previous[i] >= 0.0 and _previous[next] >= 0.0:
				_dashed(prior[i], prior[next])

	var poly := _polygon(center, radius, _values, count, _grow)
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_colored_polygon(closed, Color(_accent.r, _accent.g, _accent.b, 0.13))
	draw_polyline(closed, Color(_accent.r, _accent.g, _accent.b, 0.9), 2.0, true)
	for i in count:
		if _values[i] < 0.0:
			draw_circle(poly[i], 2.4, Color(_ink.r, _ink.g, _ink.b, 0.25))
			continue
		draw_circle(poly[i], 3.2, _accent)

	for i in count:
		var angle := -PI * 0.5 + TAU * float(i) / float(count)
		var at := center + Vector2(cos(angle), sin(angle)) * (radius + 20.0)
		var label: String = _names[i]
		var width: float = _text_width(label, 15, "body")
		var x: float = at.x - width * 0.5
		if cos(angle) > 0.35:
			x = at.x
		elif cos(angle) < -0.35:
			x = at.x - width
		var value_text := "—" if _values[i] < 0.0 else "%.0f%%" % _values[i]
		_text(Vector2(x, at.y + 4.0), label, 15, _ink, "body")
		var value_width: float = _text_width(value_text, 13, "label")
		var value_x: float = x
		if cos(angle) > 0.35:
			value_x = x
		elif cos(angle) < -0.35:
			value_x = x + width - value_width
		else:
			value_x = x + width * 0.5 - value_width * 0.5
		_text(Vector2(value_x, at.y + 22.0), value_text, 13, _muted, "label")

	if _previous.size() == count:
		_right_text(size.x, size.y - 6.0, "实线为本年，虚线为上年", 13, Color(_muted.r, _muted.g, _muted.b, 0.7), "label")


func _polygon(center: Vector2, radius: float, values: PackedFloat64Array, count: int, scale: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in count:
		var value: float = clampf(values[i] / 100.0, 0.0, 1.0) if i < values.size() else 0.0
		var angle := -PI * 0.5 + TAU * float(i) / float(count)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius * value * scale)
	return points


func _dashed(a: Vector2, b: Vector2) -> void:
	var length := a.distance_to(b)
	var steps: int = maxi(2, int(length / 7.0))
	for s in range(0, steps, 2):
		var t0 := float(s) / float(steps)
		var t1 := float(s + 1) / float(steps)
		draw_line(a.lerp(b, t0), a.lerp(b, t1), Color(_brass.r, _brass.g, _brass.b, 0.55), 1.0, true)
