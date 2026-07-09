extends PanelContainer
class_name MetricCard

var _title_label: Label
var _value_label: Label
var _subtitle_label: Label
var _trend_label: Label
var _icon_badge: IconBadge
var _accent: Color = UITokens.ACCENT


func _ready() -> void:
	if _title_label != null:
		return
	add_theme_stylebox_override("panel", UITokens.panel_style(UITokens.CARD_BG, UITokens.RADIUS_SM, Color(_accent.r, _accent.g, _accent.b, 0.32)))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_XS)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_XS)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(row)

	_icon_badge = IconBadge.new()
	_icon_badge.custom_minimum_size = Vector2(26.0, 28.0)
	row.add_child(_icon_badge)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 1)
	row.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	_title_label = Label.new()
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_trend_label = Label.new()
	_trend_label.add_theme_color_override("font_color", _accent)
	header.add_child(_trend_label)

	_value_label = Label.new()
	_value_label.add_theme_font_size_override("font_size", 16)
	_value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	box.add_child(_value_label)

	_subtitle_label = Label.new()
	_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	box.add_child(_subtitle_label)


func set_data(title: String, value: String, subtitle: String = "", accent: Color = UITokens.ACCENT, trend: String = "", icon: String = "") -> void:
	_accent = accent
	if _title_label == null:
		_ready()
	add_theme_stylebox_override("panel", UITokens.panel_style(UITokens.CARD_BG, UITokens.RADIUS_SM, Color(accent.r, accent.g, accent.b, 0.32)))
	if _icon_badge != null:
		_icon_badge.set_icon(icon, accent)
	_title_label.text = title
	_value_label.text = value
	_subtitle_label.text = subtitle
	_subtitle_label.visible = subtitle != ""
	_trend_label.text = trend
	_trend_label.visible = trend != ""
	_trend_label.add_theme_color_override("font_color", accent)
