extends Control
class_name GaugeBar

var label: String = ""
var value: float = 0.0
var min_label: String = ""
var max_label: String = ""
var status_label: String = ""
var value_text: String = ""
var accent: Color = UITokens.ACCENT
var marker: float = -1.0

var _display_value: float = 0.0
var _title_label: Label
var _value_label: Label
var _value_tween: Tween


func _ready() -> void:
	if _title_label != null:
		return
	_title_label = get_node_or_null("Top/TitleLabel") as Label
	_value_label = get_node_or_null("Top/ValueLabel") as Label
	if _title_label == null or _value_label == null:
		push_error("GaugeBar 必须通过 gauge_bar.tscn 实例化。")
		return
	_value_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_refresh_labels()


func set_data(p_label: String, p_value: float, p_min_label: String = "", p_max_label: String = "", p_accent: Color = UITokens.ACCENT, p_marker: float = -1.0, p_status_label: String = "", p_value_text: String = "") -> void:
	label = p_label
	value = clampf(p_value, 0.0, 1.0)
	min_label = p_min_label
	max_label = p_max_label
	accent = p_accent
	marker = p_marker
	status_label = p_status_label
	value_text = p_value_text
	if _title_label == null:
		_ready()
	_refresh_labels()
	if is_equal_approx(_display_value, value):
		queue_redraw()
		return
	if _value_tween != null and _value_tween.is_valid():
		_value_tween.kill()
	var from := _display_value
	_value_tween = create_tween()
	_value_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_value_tween.tween_method(func(v: float) -> void:
		_display_value = v
		queue_redraw()
	, from, value, UITokens.ANIM_MED)


func _refresh_labels() -> void:
	if _title_label == null:
		return
	_title_label.text = label
	if value_text != "":
		_value_label.text = "%s · %s" % [value_text, status_label] if status_label != "" else value_text
	else:
		_value_label.text = "%d%% · %s" % [int(round(value * 100.0)), status_label] if status_label != "" else "%d%%" % int(round(value * 100.0))


func _draw() -> void:
	var y := 30.0
	var bar_rect := Rect2(Vector2(0.0, y), Vector2(size.x, 9.0))
	draw_rect(bar_rect, Color(0.035, 0.032, 0.028, 0.94), true)
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * clampf(_display_value, 0.0, 1.0), bar_rect.size.y)), Color(accent.r, accent.g, accent.b, 0.92), true)
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * clampf(_display_value, 0.0, 1.0), 2.0)), Color(1.0, 0.92, 0.74, 0.24), true)
	draw_rect(bar_rect, UITokens.PANEL_BORDER_SOFT, false, 1.0)
	if marker >= 0.0:
		var mx := bar_rect.position.x + bar_rect.size.x * clampf(marker, 0.0, 1.0)
		draw_line(Vector2(mx, y - 3.0), Vector2(mx, y + bar_rect.size.y + 3.0), Color(1.0, 1.0, 1.0, 0.70), 1.0)
	if status_label == "" and min_label != "":
		draw_string(get_theme_default_font(), Vector2(0.0, y + 24.0), min_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, UITokens.TEXT_FAINT)
	if status_label == "" and max_label != "":
		draw_string(get_theme_default_font(), Vector2(0.0, y + 24.0), max_label, HORIZONTAL_ALIGNMENT_RIGHT, size.x, 11, UITokens.TEXT_FAINT)
