extends PanelContainer
class_name MetricCard

var _title_label: Label
var _value_label: Label
var _value_icon: TextureRect
var _subtitle_label: Label
var _trend_label: Label
var _icon_badge: IconBadge
var _accent: Color = UITokens.ACCENT
var _data_signature := ""
var _compact := false
var _icon_only_presentation := false
var _compact_icon_label_presentation := false


func _ready() -> void:
	if _title_label != null:
		return
	_icon_badge = get_node_or_null("Margin/Row/IconBadge") as IconBadge
	_title_label = get_node_or_null("Margin/Row/Text/Header/TitleLabel") as Label
	_trend_label = get_node_or_null("Margin/Row/Text/Header/TrendLabel") as Label
	_value_icon = get_node_or_null("Margin/Row/Text/ValueRow/ValueIcon") as TextureRect
	_value_label = get_node_or_null("Margin/Row/Text/ValueRow/ValueLabel") as Label
	_subtitle_label = get_node_or_null("Margin/Row/Text/SubtitleLabel") as Label
	if _icon_badge == null or _title_label == null or _trend_label == null \
			or _value_label == null or _subtitle_label == null:
		push_error("MetricCard 必须通过 metric_card.tscn 实例化。")
		return
	# 金额卡片的单位是金币图标，不写字（见 MoneyDisplay）。
	MoneyDisplay.apply_icon(_value_icon, 16)
	_trend_label.add_theme_font_size_override("font_size", 11)
	_value_label.add_theme_font_override("font", UITokens.font_with_weight(650))


func set_data(title: String, value: String, subtitle: String = "",
		accent: Color = UITokens.ACCENT, trend: String = "", icon: String = "",
		money: bool = false) -> void:
	if _title_label == null:
		_ready()
	var signature := "%s|%s|%s|%s|%s|%s|%s" % [
		title, value, subtitle, accent.to_html(), trend, icon, money,
	]
	if signature == _data_signature:
		return
	_data_signature = signature
	_accent = accent
	if _icon_badge != null:
		_icon_badge.set_semantic(StringName(icon), accent)
		_icon_badge.visible = _icon_only_presentation \
			or _compact_icon_label_presentation or not _compact
	_title_label.text = title
	# 金额读数才配金币：百分比、天数、率这类读数保持纯文字。
	# 万一读数串里还带着旧单位记号（¥ / 货币），这里一并摘掉，避免「金币 + ¥」双写。
	var shown := MoneyDisplay.strip_unit(value) if money else value
	if _value_icon != null:
		_value_icon.visible = money and shown != "—"
	_value_label.text = shown
	_subtitle_label.text = subtitle
	_subtitle_label.visible = subtitle != "" and not _compact
	tooltip_text = "%s：%s" % [title, shown] if subtitle.is_empty() \
		else "%s：%s\n%s" % [title, shown, subtitle]
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
		_icon_badge.visible = _icon_only_presentation \
			or _compact_icon_label_presentation or not compact
	if _title_label != null:
		_title_label.visible = not _icon_only_presentation
	if _subtitle_label != null:
		_subtitle_label.visible = not compact and not _subtitle_label.text.is_empty()


func set_icon_only_presentation(enabled: bool) -> void:
	if _title_label == null:
		_ready()
	_icon_only_presentation = enabled
	_compact_icon_label_presentation = false
	if _icon_badge != null:
		_icon_badge.visible = enabled or not _compact
	if _title_label != null:
		_title_label.visible = not enabled
	if _subtitle_label != null:
		_subtitle_label.visible = not enabled and not _compact \
			and not _subtitle_label.text.is_empty()


func set_compact_icon_label_presentation(enabled: bool) -> void:
	if _title_label == null:
		_ready()
	_compact = true
	_compact_icon_label_presentation = enabled
	_icon_only_presentation = false
	if _icon_badge != null:
		_icon_badge.visible = enabled
	if _title_label != null:
		_title_label.visible = true
	if _subtitle_label != null:
		_subtitle_label.visible = false
