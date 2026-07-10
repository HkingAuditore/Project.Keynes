extends HBoxContainer
class_name BadgeRow

var _labels: Array[Label] = []


func set_badges(badges: Array) -> void:
	for child in get_children():
		child.queue_free()
	_labels.clear()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	for item in badges:
		var data: Dictionary = item
		var badge := Label.new()
		badge.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		badge.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		_apply_badge(badge, data)
		add_child(badge)
		_labels.append(badge)


func update_badges(badges: Array) -> void:
	if badges.size() != _labels.size():
		return
	for i in range(badges.size()):
		_apply_badge(_labels[i], badges[i])


func _apply_badge(badge: Label, data: Dictionary) -> void:
	badge.text = String(data.get("text", "—"))
	var accent: Color = data.get("accent", UITokens.ACCENT)
	badge.add_theme_color_override("font_color", accent.lerp(UITokens.TEXT_MAIN, 0.38))
	var style := UITokens.inset_panel_style(
		Color(0.060, 0.052, 0.042, 0.92),
		Color(accent.r, accent.g, accent.b, 0.56),
		UITokens.RADIUS_SM
	)
	style.content_margin_left = UITokens.SPACE_SM
	style.content_margin_right = UITokens.SPACE_SM
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	style.shadow_size = 0
	badge.add_theme_stylebox_override("normal", style)
