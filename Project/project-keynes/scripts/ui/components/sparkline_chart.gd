extends Control
class_name SparklineChart

var title: String = ""
var values: Array = []
var accent: Color = UITokens.ACCENT
var min_value: float = NAN
var max_value: float = NAN
var window_size: int = 0
var value_text: String = ""

var _title_label: Label
var _value_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(180.0, 96.0)
	if _title_label != null:
		return
	_title_label = Label.new()
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.offset_right = -112.0
	_title_label.offset_bottom = 24.0
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	add_child(_title_label)
	_value_label = Label.new()
	_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_value_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_value_label.anchor_left = 1.0
	_value_label.offset_left = -108.0
	_value_label.offset_bottom = 24.0
	_value_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	add_child(_value_label)


func set_data(
		p_title: String,
		p_values: Array,
		p_accent: Color = UITokens.ACCENT,
		p_min_value: float = NAN,
		p_max_value: float = NAN,
		p_window_size: int = 0,
		p_value_text: String = ""
) -> void:
	title = p_title
	values = p_values.duplicate()
	accent = p_accent
	min_value = p_min_value
	max_value = p_max_value
	window_size = maxi(p_window_size, 0)
	value_text = p_value_text
	if _title_label == null:
		_ready()
	_title_label.text = title
	_value_label.text = value_text
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2(0.0, 28.0), Vector2(size.x, maxf(size.y - 32.0, 20.0)))
	draw_rect(rect, Color(0.027, 0.026, 0.023, 0.88), true)
	for i in range(1, 4):
		var grid_y := rect.position.y + rect.size.y * (float(i) / 4.0)
		draw_line(Vector2(rect.position.x, grid_y), Vector2(rect.end.x, grid_y), Color(0.70, 0.55, 0.31, 0.10), 1.0)
	draw_rect(rect, UITokens.PANEL_BORDER_SOFT, false, 1.0)
	if values.is_empty():
		draw_string(get_theme_default_font(), rect.position + Vector2(10.0, rect.size.y * 0.58), "暂无观测", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, UITokens.TEXT_FAINT)
		return
	var range_min := min_value
	var range_max := max_value
	if is_nan(range_min) or is_nan(range_max) or range_max <= range_min:
		range_min = INF
		range_max = -INF
		for raw in values:
			var v := float(raw)
			range_min = minf(range_min, v)
			range_max = maxf(range_max, v)
		var auto_span := maxf(range_max - range_min, 0.001)
		var padding := maxf(auto_span * 0.12, 0.01)
		range_min -= padding
		range_max += padding
	var span := maxf(range_max - range_min, 0.001)
	var slots := maxi(window_size, values.size())
	slots = maxi(slots, 2)
	var pts := PackedVector2Array()
	for i in range(values.size()):
		var x := rect.position.x + rect.size.x * (float(i) / float(slots - 1))
		var norm := clampf((float(values[i]) - range_min) / span, 0.0, 1.0)
		var y := rect.position.y + rect.size.y * (1.0 - norm)
		pts.append(Vector2(x, y))
	if pts.size() == 1:
		draw_circle(pts[0], 3.0, accent)
		draw_string(get_theme_default_font(), rect.position + Vector2(10.0, rect.size.y * 0.58), "正在积累逐日样本", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, UITokens.TEXT_FAINT)
		return
	var fill_pts := pts.duplicate()
	fill_pts.append(Vector2(pts[pts.size() - 1].x, rect.end.y))
	fill_pts.append(Vector2(pts[0].x, rect.end.y))
	draw_colored_polygon(fill_pts, Color(accent.r, accent.g, accent.b, 0.10))
	draw_polyline(pts, Color(0.0, 0.0, 0.0, 0.52), 4.0, true)
	draw_polyline(pts, accent, 2.0, true)
	draw_circle(pts[pts.size() - 1], 3.0, Color(accent.r, accent.g, accent.b, 0.96))
