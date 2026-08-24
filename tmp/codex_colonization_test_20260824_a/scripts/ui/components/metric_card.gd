extends PanelContainer
class_name MetricCard

var _title_label: Label
var _value_label: Label
var _subtitle_label: Label
var _trend_label: Label
var _icon_badge: IconBadge
var _accent: Color = UITokens.ACCENT
var _data_signature := ""
var _compact := false


func _ready() -> void:
	if _title_label != null:
		return
	_icon_badge = get_node_or_null("Margin/Row/IconBadge") as IconBadge
	_title_label = get_node_or_null("Margin/Row/Text/Header/TitleLabel") as Label
	_trend_label = get_node_or_null("Margin/Row/Text/Header/TrendLabel") as Label
	_value_label = get_node_or_null("Margin/Row/Text/ValueLabel") as Label
	_subtitle_label = get_node_or_null("Margin/Row/Text/SubtitleLabel") as Label
	if _icon_badge == null or _title_label == null or _trend_label == null \
			or _value_label == null or _subtitle_label == null:
		push_error("MetricCard 必须通过 metric_card.tscn 实例化。")
		return
	_trend_label.add_theme_font_override("font", IconBadge.FA_SOLID_FONT)
	_trend_label.add_theme_font_size_override("font_size", 11)
	_value_label.add_theme_font_override("font", UITokens.font_with_weight(650))


func set_data(title: String, value: String, subtitle: String = "", accent: Color = UITokens.ACCENT, trend: String = "", icon: String = "") -> void:
	if _title_label == null:
		_ready()
	var signature := "%s|%s|%s|%s|%s|%s" % [
		title, value, subtitle, accent.to_html(), trend, icon,
	]
	if signature == _data_signature:
		return
	_data_signature = signature
	_accent = accent
	if _icon_badge != null:
		_icon_badge.set_semantic(StringName(icon), accent)
		_icon_badge.visible = not _compact
	_title_label.text = title
	_value_label.text = value
	_subtitle_label.text = subtitle
	_subtitle_label.visible = subtitle != "" and not _compact
	tooltip_text = "%s：%s" % [title, value] if subtitle.is_empty() \
		else "%s：%s\n%s" % [title, value, subtitle]
	var trend_key := IconCatalog.resolve_semantic(StringName(trend))
	if trend_key == &"":
		_trend_label.text = ""
	else:
		IconButton.apply_to_label(_trend_label, StringName(trend_key), UITokens.FONT_SMALL)
	_trend_label.visible = trend != ""
	_trend_label.add_theme_color_override("font_color", accent)


func set_compact(compact: bool) -> void:
	if _title_label == null:
		_ready()
	_compact = compact
	if _icon_badge != null:
		_icon_badge.visible = not compact
	if _subtitle_label != null:
		_subtitle_label.visible = not compact and not _subtitle_label.text.is_empty()
