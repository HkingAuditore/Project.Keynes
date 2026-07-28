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
	clip_contents = true
	add_theme_stylebox_override("panel", UITokens.inset_panel_style(Color(0.074, 0.061, 0.046, 0.96), Color(_accent.r, _accent.g, _accent.b, 0.42)))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 5)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(row)

	_icon_badge = IconBadge.new()
	_icon_badge.custom_minimum_size = Vector2(24.0, 26.0)
	row.add_child(_icon_badge)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 1)
	row.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_trend_label = Label.new()
	_trend_label.add_theme_font_override("font", IconBadge.FA_SOLID_FONT)
	_trend_label.add_theme_font_size_override("font_size", 11)
	_trend_label.add_theme_color_override("font_color", _accent)
	header.add_child(_trend_label)

	_value_label = Label.new()
	_value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_value_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_value_label.add_theme_font_size_override("font_size", 16)
	_value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	box.add_child(_value_label)

	_subtitle_label = Label.new()
	_subtitle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	box.add_child(_subtitle_label)


func set_data(title: String, value: String, subtitle: String = "", accent: Color = UITokens.ACCENT, trend: String = "", icon: String = "") -> void:
	_accent = accent
	if _title_label == null:
		_ready()
	add_theme_stylebox_override("panel", UITokens.inset_panel_style(Color(0.074, 0.061, 0.046, 0.96), Color(accent.r, accent.g, accent.b, 0.46)))
	if _icon_badge != null:
		_icon_badge.set_semantic(StringName(icon), accent)
	_title_label.text = title
	_value_label.text = value
	_subtitle_label.text = subtitle
	_subtitle_label.visible = subtitle != ""
	var trend_key := IconCatalog.resolve_semantic(StringName(trend))
	if trend_key == &"":
		_trend_label.text = ""
	else:
		IconButton.apply_to_label(_trend_label, StringName(trend_key), UITokens.FONT_SMALL)
	_trend_label.visible = trend != ""
	_trend_label.add_theme_color_override("font_color", accent)
