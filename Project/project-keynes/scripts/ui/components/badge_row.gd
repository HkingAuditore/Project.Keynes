extends HBoxContainer
class_name BadgeRow


func set_badges(badges: Array) -> void:
	for child in get_children():
		child.queue_free()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	for item in badges:
		var data: Dictionary = item
		var badge := Label.new()
		badge.text = String(data.get("text", "—"))
		var accent: Color = data.get("accent", UITokens.ACCENT)
		badge.add_theme_color_override("font_color", Color(accent.r * 1.18, accent.g * 1.14, accent.b * 1.08, 1.0))
		badge.add_theme_stylebox_override("normal", UITokens.button_style(Color(0.10, 0.08, 0.055, 0.88), Color(accent.r, accent.g, accent.b, 0.56), UITokens.RADIUS_SM))
		add_child(badge)
