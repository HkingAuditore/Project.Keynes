extends Control
class_name RadialGauge

var title: String = ""
var value: float = 0.0
var caption: String = ""
var accent: Color = UITokens.ACCENT

var _display_value: float = 0.0
var _title_label: Label
var _caption_label: Label
var _value_tween: Tween
var _value_font: Font = UITokens.font_with_weight(700)


func _ready() -> void:
	if _title_label != null:
		return
	_title_label = get_node_or_null("TitleLabel") as Label
	_caption_label = get_node_or_null("CaptionLabel") as Label
	if _title_label == null or _caption_label == null:
		push_error("RadialGauge 必须通过 radial_gauge.tscn 实例化。")
		return
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(650))


func set_data(p_title: String, p_value: float, p_caption: String = "", p_accent: Color = UITokens.ACCENT) -> void:
	title = p_title
	value = clampf(p_value, 0.0, 1.0)
	caption = p_caption
	accent = p_accent
	if _title_label == null:
		_ready()
	_title_label.text = title
	_caption_label.text = caption
	if is_equal_approx(_display_value, value):
		queue_redraw()
		return
	if _value_tween != null and _value_tween.is_valid():
		_value_tween.kill()
	_value_tween = create_tween()
	_value_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_value_tween.tween_method(func(v: float) -> void:
		_display_value = v
		queue_redraw()
	, _display_value, value, UITokens.ANIM_MED)


func _draw() -> void:
	var center := Vector2(size.x * 0.5, 50.0)
	var radius := minf(size.x, 104.0) * 0.34
	draw_arc(center, radius, deg_to_rad(135), deg_to_rad(405), 48, Color(0.030, 0.028, 0.024, 0.96), 9.0, true)
	draw_arc(center, radius + 5.0, deg_to_rad(135), deg_to_rad(405), 48, UITokens.PANEL_BORDER_SOFT, 1.0, true)
	draw_arc(center, radius, deg_to_rad(135), deg_to_rad(135 + 270.0 * clampf(_display_value, 0.0, 1.0)), 48, Color(accent.r, accent.g, accent.b, 0.88), 7.0, true)
	for i in range(7):
		var angle := deg_to_rad(135.0 + 45.0 * float(i))
		var inner := center + Vector2(cos(angle), sin(angle)) * (radius + 8.0)
		var outer := center + Vector2(cos(angle), sin(angle)) * (radius + 11.0)
		draw_line(inner, outer, UITokens.PANEL_BORDER, 1.0, true)
	var pct := "%d%%" % int(round(_display_value * 100.0))
	var font := _value_font
	var font_size := 24
	var text_size := font.get_string_size(pct, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	draw_string(font, center + Vector2(-text_size.x * 0.5, 8.0), pct, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, UITokens.TEXT_MAIN)
