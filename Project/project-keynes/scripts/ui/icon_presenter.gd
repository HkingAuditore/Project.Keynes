class_name IconPresenter
extends RefCounted


static func apply_to_button(
		button: Button,
		semantic_key: String,
		font_size: int = 16,
		_family = null
) -> void:
	IconButton.apply(button, StringName(semantic_key), font_size)


static func apply_to_label(label: Label, semantic_key: String, font_size: int = 16) -> void:
	IconButton.apply_to_label(label, StringName(semantic_key), font_size)
