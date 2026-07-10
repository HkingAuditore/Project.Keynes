extends Control
class_name SparklineChart

var title: String = ""
var values: Array = []
var accent: Color = UITokens.ACCENT

var _title_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(180.0, 88.0)
	if _title_label != null:
		return
	_title_label = Label.new()
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.offset_bottom = 22.0
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	add_child(_title_label)


func set_data(p_title: String, p_values: Array, p_accent: Color = UITokens.ACCENT) -> void:
	title = p_title
	values = p_values.duplicate()
	accent = p_accent
	if _title_label == null:
		_ready()
	_title_label.text = title
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2(0.0, 26.0), Vector2(size.x, maxf(size.y - 30.0, 20.0)))
	draw_rect(rect, Color(0.027, 0.026, 0.023, 0.88), true)
	for i in range(1, 4):
		var grid_y := rect.position.y + rect.size.y * (float(i) / 4.0)
		draw_line(Vector2(rect.position.x, grid_y), Vector2(rect.end.x, grid_y), Color(0.70, 0.55, 0.31, 0.10), 1.0)
	draw_rect(rect, UITokens.PANEL_BORDER_SOFT, false, 1.0)
	if values.size() < 2:
		draw_string(get_theme_default_font(), rect.position + Vector2(10.0, rect.size.y * 0.58), "暂无趋势", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, UITokens.TEXT_FAINT)
		return
	var min_v := INF
	var max_v := -INF
	for raw in values:
		var v := float(raw)
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)
	var span := maxf(max_v - min_v, 0.001)
	var pts := PackedVector2Array()
	for i in range(values.size()):
		var x := rect.position.x + rect.size.x * (float(i) / float(values.size() - 1))
		var norm := (float(values[i]) - min_v) / span
		var y := rect.position.y + rect.size.y * (1.0 - norm)
		pts.append(Vector2(x, y))
	var fill_pts := pts.duplicate()
	fill_pts.append(Vector2(rect.end.x, rect.end.y))
	fill_pts.append(Vector2(rect.position.x, rect.end.y))
	draw_colored_polygon(fill_pts, Color(accent.r, accent.g, accent.b, 0.10))
	draw_polyline(pts, Color(0.0, 0.0, 0.0, 0.52), 4.0, true)
	draw_polyline(pts, accent, 2.0, true)
	for pt in pts:
		draw_circle(pt, 2.2, Color(accent.r, accent.g, accent.b, 0.92))
