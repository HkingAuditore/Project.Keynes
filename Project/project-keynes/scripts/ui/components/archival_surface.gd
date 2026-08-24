extends Control
class_name ArchivalSurface

## Shared presentation shell for formal player-session workspaces. It owns only
## visual chrome and layout slots; callers keep their existing view models and
## command/event wiring.

@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _icon: TextureRect = %Icon
@onready var _body: VBoxContainer = %Body
@onready var _frame: PanelContainer = %Frame

var _compact := false


func _ready() -> void:
	_apply_compact()


func configure_header(title: String, subtitle: String = "",
		icon_key: StringName = &"") -> void:
	if _title == null:
		_ready()
	_title.text = title
	_subtitle.text = subtitle
	_subtitle.visible = not subtitle.is_empty()
	_icon.visible = not icon_key.is_empty()
	if not icon_key.is_empty():
		_icon.texture = IconCatalog.texture_for_key(icon_key)


func set_compact(compact: bool) -> void:
	_compact = compact
	_apply_compact()


func body() -> VBoxContainer:
	return _body


func add_body_control(control: Control) -> void:
	if control == null or _body == null:
		return
	_body.add_child(control)


func clear_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		child.queue_free()


func _apply_compact() -> void:
	if _frame == null:
		return
	_frame.add_theme_constant_override("separation", 6 if _compact else 10)
	_body.add_theme_constant_override("separation", 6 if _compact else 10)
	_title.add_theme_font_size_override("font_size", 22 if _compact else 28)
	_subtitle.add_theme_font_size_override("font_size", 13 if _compact else 15)
	_icon.custom_minimum_size = Vector2(24, 24) if _compact else Vector2(32, 32)
