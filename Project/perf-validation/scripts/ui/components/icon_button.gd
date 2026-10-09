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
	var texture := IconCatalog.texture_for_key(semantic_key)
	var label := IconCatalog.label_for_key(semantic_key)
	button.icon = texture
	button.expand_icon = texture != null
	if texture != null:
		button.text = ""
		button.remove_theme_font_override("font")
		button.remove_theme_font_size_override("font_size")
		return
	if not label.is_empty():
		button.text = label
		button.remove_theme_font_override("font")
		button.add_theme_font_size_override("font_size", maxi(10, icon_size - 2))
		return
	button.text = IconCatalog.glyph_for_key(semantic_key)
	button.add_theme_font_override("font", IconCatalog.FONT_AWESOME)
	button.add_theme_font_size_override("font_size", icon_size)


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


static func apply_to_label(
		label: Label,
		semantic_key: StringName,
		icon_size: int = MEDIUM
) -> void:
	if label == null:
		return
	var material_label := IconCatalog.label_for_key(semantic_key)
	label.text = material_label if not material_label.is_empty() \
		else IconCatalog.glyph_for_key(semantic_key)
	if not material_label.is_empty():
		label.remove_theme_font_override("font")
		label.add_theme_font_size_override("font_size", maxi(10, icon_size - 2))
		return
	label.add_theme_font_override("font", IconCatalog.FONT_AWESOME)
	label.add_theme_font_size_override("font_size", icon_size)
