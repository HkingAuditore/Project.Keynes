extends HFlowContainer
class_name BadgeRow

const BadgeLabelScene := preload("res://scenes/ui/badge_label.tscn")

# Ellipsis trimming drops the text out of a Label's minimum size, so a badge in
# an HBoxContainer would otherwise shrink to its padding and render blank. The
# natural text width is reserved explicitly, capped so one long badge cannot push
# the row past its panel.
const MAX_BADGE_WIDTH := 132.0

var _labels: Array[Label] = []


func set_badges(badges: Array) -> void:
	for child in get_children():
		child.queue_free()
	_labels.clear()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	for item in badges:
		var data: Dictionary = item
		var badge := BadgeLabelScene.instantiate() as Label
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
	var measured := UITokens.UI_FONT.get_string_size(badge.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL).x
	badge.custom_minimum_size.x = minf(measured, MAX_BADGE_WIDTH) \
		+ float(UITokens.SPACE_SM) * 2.0 + 7.0
	var accent: Color = data.get("accent", UITokens.ACCENT)
	badge.add_theme_color_override("font_color", accent.lerp(UITokens.TEXT_MAIN, 0.38))
