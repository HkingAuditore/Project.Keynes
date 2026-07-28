extends Control
class_name SectionPlaceholderScreen

var _icon: IconBadge
var _title: Label
var _detail: Label


func _ready() -> void:
	if _title != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", UITokens.SPACE_MD)
	add_child(column)
	_icon = IconBadge.new()
	_icon.custom_minimum_size = Vector2(56.0, 56.0)
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_icon.set_semantic(&"country.affairs", UITokens.TEXT_MUTED)
	column.add_child(_icon)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", UITokens.font_with_weight(650))
	_title.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	_title.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	column.add_child(_title)
	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_detail.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	column.add_child(_detail)


func set_section(label: String, icon: StringName, accent: Color) -> void:
	if _title == null:
		_ready()
	_icon.set_semantic(icon, accent)
	_title.text = "%s事务建设中" % label
	_detail.text = "该领域尚未接入模拟与操作命令。"
