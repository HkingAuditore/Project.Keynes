extends AnnualChartBase
class_name AnnualMonthChart

## 十二个月已结算 GDP 的面积图。
## 只画面积、折线、末点，加一条基线与三条发丝线；没有网格、没有外框。
## 未观测月份保留空槽（虚线底），所以"只走了七个月"这件事在图上直接看得见。

var _series := PackedFloat64Array()
var _observed := 0
var _compact := false


func set_data(series: PackedFloat64Array, observed: int) -> bool:
	_series = series
	_observed = clampi(observed, 0, series.size())
	if _observed < 1:
		return false
	_start_reveal()
	return true


func set_compact(value: bool) -> void:
	_compact = value
	custom_minimum_size.y = 76.0 if value else 240.0
	queue_redraw()


func _draw() -> void:
	if _series.is_empty() or _observed < 1:
		return
	var w: float = size.x
	var h: float = size.y
	var gutter: float = 0.0 if _compact else 148.0
	var top: float = 10.0 if _compact else 30.0
	var bottom: float = 12.0 if _compact else 42.0
	var plot := Rect2(0.0, top, maxf(24.0, w - gutter), maxf(12.0, h - top - bottom))

	var hi: float = 0.0
	for i in _observed:
		hi = maxf(hi, _series[i])
	if hi <= 0.0:
		return
	var pitch: float = plot.size.x / 11.0
	var points := PackedVector2Array()
	for i in _observed:
		var ratio: float = _series[i] / hi
		points.append(Vector2(plot.position.x + pitch * i, plot.end.y - plot.size.y * ratio * _grow))

	# 发丝线：只在非紧凑模式，三条，很淡。
	if not _compact:
		for step in [0.25, 0.5, 0.75]:
			_hairline(plot.end.y - plot.size.y * float(step), plot.position.x, plot.end.x, 0.07)

	# 未观测月份的空槽
	if _observed < 12:
		for i in range(_observed, 12):
			var x: float = plot.position.x + pitch * i
			draw_line(Vector2(x, plot.end.y), Vector2(x, plot.end.y - 6.0), Color(_ink.r, _ink.g, _ink.b, 0.12), 1.0, true)

	var area := PackedVector2Array()
	area.append(Vector2(points[0].x, plot.end.y))
	for point in points:
		area.append(point)
	area.append(Vector2(points[points.size() - 1].x, plot.end.y))
	draw_colored_polygon(area, Color(_accent.r, _accent.g, _accent.b, 0.10))

	if points.size() > 1:
		draw_polyline(points, Color(_ink.r, _ink.g, _ink.b, 0.86), 2.0, true)
	var last: Vector2 = points[points.size() - 1]
	draw_circle(last, 3.0, _accent)

	_baseline(plot.end.y, plot.position.x, plot.end.x)

	if _compact:
		var head := UITokens.format_compact_number_cn(_series[_observed - 1])
		_right_text(w, plot.position.y + 16.0, head, 19, _ink, "numeral")
		return

	# 月份刻度：只标 1 / 4 / 7 / 10 月，避免 12 个数字挤成一排。
	for month in [0, 3, 6, 9]:
		var x: float = plot.position.x + pitch * month
		_caption(Vector2(x - 6.0, plot.end.y + 20.0), "%d 月" % (month + 1))

	# 极值标注：最高点与最低点各一个小标签。
	var hi_index := 0
	var lo_index := 0
	for i in _observed:
		if _series[i] > _series[hi_index]:
			hi_index = i
		if _series[i] < _series[lo_index]:
			lo_index = i
	var hi_point: Vector2 = points[hi_index]
	_caption(Vector2(hi_point.x - 4.0, hi_point.y - 9.0), UITokens.format_compact_number_cn(_series[hi_index]) + "  峰值")
	var lo_point: Vector2 = points[lo_index]
	_caption(Vector2(lo_point.x - 4.0, lo_point.y + 18.0), "谷值 " + UITokens.format_compact_number_cn(_series[lo_index]))

	# 右栏：末值与"已观测 N 个月"
	var tail := UITokens.format_compact_number_cn(_series[_observed - 1])
	_figure(Vector2(plot.end.x + 24.0, plot.position.y + 30.0), tail, 40, _ink)
	_caption(Vector2(plot.end.x + 26.0, plot.position.y + 50.0), "12 月末值" if _observed >= 12 else "第 %d 月" % _observed)
	_caption(Vector2(plot.end.x + 26.0, plot.position.y + 70.0), "已观测 %d 个月" % _observed, Color(_muted.r, _muted.g, _muted.b, 0.7))
