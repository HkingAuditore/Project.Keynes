class_name IconButton
extends RefCounted


const SMALL := 14
const MEDIUM := 16
const LARGE := 21


static func apply(
		button: Button,
		semantic_key: StringName,
		icon_size: int = MEDIUM,
		tooltip: String = "",
		toggle: bool = false,
		active: bool = false
) -> void:
	if button == null:
		return
	configure(button, tooltip, toggle, active)
	preload("res://scripts/ui/ui_audio_feedback.gd").tag_icon(button, semantic_key)
	var texture := IconCatalog.texture_for_key(semantic_key)
	button.icon = texture
	button.expand_icon = false
	_apply_paper_colours(button, semantic_key)
	button.text = ""
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", icon_size)
	button.remove_theme_font_override("font")
	button.remove_theme_font_size_override("font_size")


static func apply_with_text(
		button: Button,
		semantic_key: StringName,
		text_value: String,
		icon_size: int = MEDIUM,
		tooltip: String = "",
		toggle: bool = false,
		active: bool = false
) -> void:
	if button == null:
		return
	configure(button, tooltip, toggle, active)
	preload("res://scripts/ui/ui_audio_feedback.gd").tag_icon(button, semantic_key)
	var texture := IconCatalog.texture_for_key(semantic_key)
	button.icon = texture
	button.expand_icon = false
	_apply_paper_colours(button, semantic_key)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("icon_max_width", icon_size)
	button.text = text_value
	button.remove_theme_font_override("font")


static func configure(
		button: Button,
		tooltip: String = "",
		toggle: bool = false,
		active: bool = false
) -> void:
	if button == null:
		return
	if not tooltip.is_empty():
		button.tooltip_text = tooltip
	button.toggle_mode = toggle
	if toggle:
		button.set_pressed_no_signal(active)


static func set_active(button: Button, active: bool) -> void:
	if button != null:
		button.toggle_mode = true
		button.set_pressed_no_signal(active)


static func _apply_paper_colours(button: Button, semantic_key: StringName) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		var token := "icon_%s_color" % state
		if IconCatalog.family_for_key(semantic_key) == IconCatalog.FAMILY_PAPER:
			button.add_theme_color_override(token,
				Color(1.0, 1.0, 1.0, 0.45) if state == "disabled" else Color.WHITE)
		else:
			button.remove_theme_color_override(token)


static func apply_to_label(
		label: Label,
		semantic_key: StringName,
		icon_size: int = MEDIUM
) -> void:
	if label == null:
		return
	var texture := IconCatalog.texture_for_key(semantic_key)
	var artwork := label.get_node_or_null("SemanticArtwork") as TextureRect
	if texture != null:
		if artwork == null:
			artwork = TextureRect.new()
			artwork.name = "SemanticArtwork"
			artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
			artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			label.add_child(artwork)
			artwork.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		artwork.texture = texture
		artwork.visible = true
		label.text = ""
		label.custom_minimum_size = Vector2(icon_size, icon_size)
		return
	if artwork != null:
		artwork.visible = false
	label.text = ""
	label.remove_theme_font_override("font")
