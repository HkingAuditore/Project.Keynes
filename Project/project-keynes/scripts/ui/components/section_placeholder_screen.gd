extends Control
class_name SectionPlaceholderScreen

var _icon: IconBadge
var _title: Label
var _detail: Label


func _ready() -> void:
	if _title != null:
		return
	_icon = get_node_or_null("Column/Icon") as IconBadge
	_title = get_node_or_null("Column/Title") as Label
	_detail = get_node_or_null("Column/Detail") as Label
	if _icon == null or _title == null or _detail == null:
		push_error("SectionPlaceholderScreen 必须通过 section_placeholder_screen.tscn 实例化。")
		return
	_icon.set_semantic(&"country.affairs", UITokens.TEXT_MUTED)


func set_section(label: String, icon: StringName, accent: Color) -> void:
	if _title == null:
		_ready()
	_icon.set_semantic(icon, accent)
	_title.text = "%s尚未开放" % label
	_detail.text = "这一事务还不能操作。"
