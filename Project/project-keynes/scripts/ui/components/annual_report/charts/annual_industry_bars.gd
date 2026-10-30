extends AnnualChartBase
class_name AnnualIndustryBars

## 分项横条：行业增加值 / 资源提取量共用。
## 主条（朱红）是增加值，副条（铜金细线）是工资，两条共用同一比例尺，
## 所以"增加值高但工资低"这种结构问题一眼能看出来。
## 超过八项折叠，明细仍完整保留在账簿与复制全文里。

var _rows: Array = []
var _cap := 8


func set_data(rows: Array, limit: int = 8) -> bool:
	if rows.is_empty():
		return false
	_rows = rows.duplicate()
	_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("value", 0.0)) > float(b.get("value", 0.0)))
	_cap = clampi(limit, 1, 12)
	var shown: int = mini(_rows.size(), _cap)
	custom_minimum_size.y = 34.0 + 34.0 * float(shown) + (26.0 if _rows.size() > _cap else 0.0)
	_start_reveal()
	return true


func _draw() -> void:
	if _rows.is_empty():
		return
	var w: float = size.x
	var label_width: float = clampf(w * 0.26, 132.0, 220.0)
	var value_width: float = 110.0
	var track_left: float = label_width + 14.0
	var track_right: float = maxf(track_left + 40.0, w - value_width - 12.0)
	var track_len: float = track_right - track_left
	var top: float = 26.0

	var max_value: float = 0.0
	for row in _rows:
		max_value = maxf(max_value, float(row.get("value", 0.0)))
	if max_value <= 0.0:
		return

	var shown: int = mini(_rows.size(), _cap)
	for i in shown:
		var row: Dictionary = _rows[i]
		var y: float = top + 34.0 * float(i)
		var label: String = _fit_text(String(row.get("label", "")), 15, label_width, "body")
		_text(Vector2(0.0, y + 4.0), label, 15, _ink, "body")
		var value: float = float(row.get("value", 0.0))
		var length: float = track_len * clampf(value / max_value, 0.0, 1.0) * _grow
		if length > 0.6:
			var colors := [UITokens.CHRONICLE_PENCIL_RED, UITokens.CHRONICLE_PENCIL_GOLD,
				UITokens.CHRONICLE_PENCIL_BLUE, UITokens.CHRONICLE_PENCIL_GREEN]
			var bar_color: Color = colors[i % colors.size()]
			var bar := Rect2(track_left, y - 7.0, length, 12.0)
			# 固定的 3px/2px 内缩在动画初期会让短条的顶点倒置，
			# Godot 无法为这种退化四边形做三角剖分。
			if length >= 4.0:
				draw_colored_polygon(PackedVector2Array([
					bar.position + Vector2(3.0, 0.0),
					Vector2(bar.end.x, bar.position.y + 1.0),
					bar.end - Vector2(2.0, 1.0),
					Vector2(bar.position.x + 1.0, bar.end.y),
				]), bar_color)
				var hatch_x := bar.position.x + 5.0
				while hatch_x < bar.end.x - 2.0:
					draw_line(Vector2(hatch_x, bar.position.y + 1.0),
						Vector2(maxf(bar.position.x, hatch_x - 7.0), bar.end.y - 1.0),
						Color(1.0, 0.96, 0.84, 0.24), 1.0, true)
					hatch_x += 8.0
			else:
				draw_line(Vector2(bar.position.x, bar.position.y + bar.size.y * 0.5),
					Vector2(bar.end.x, bar.position.y + bar.size.y * 0.5), bar_color,
					bar.size.y, true)
			draw_line(bar.position, Vector2(bar.end.x, bar.position.y),
				Color(_ink.r, _ink.g, _ink.b, 0.78), 2.0, true)
			draw_line(Vector2(bar.end.x, bar.position.y + 2.0), bar.end,
				Color(_ink.r, _ink.g, _ink.b, 0.50), 1.2, true)
		var secondary: float = float(row.get("secondary", 0.0))
		if secondary > 0.0:
			var prior: float = track_len * clampf(secondary / max_value, 0.0, 1.0) * _grow
			draw_line(Vector2(track_left, y + 8.0), Vector2(track_left + prior, y + 8.0),
				Color(UITokens.CHRONICLE_PENCIL_GREEN.r, UITokens.CHRONICLE_PENCIL_GREEN.g,
					UITokens.CHRONICLE_PENCIL_GREEN.b, 0.80), 2.0, true)
		_right_text(w, y + 2.0, UITokens.format_compact_number_cn(value), 19, _ink)

	if _rows.size() > _cap:
		_caption(Vector2(track_left, top + 34.0 * float(shown) + 8.0), "另有 %d 项未列入图内，见本章明细表" % (_rows.size() - _cap))
	_caption(Vector2(0.0, 14.0), "彩条为增加值，绿线为实付工资，同一比例尺")
