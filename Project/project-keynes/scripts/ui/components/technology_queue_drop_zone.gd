extends VBoxContainer
class_name TechnologyQueueDropZone

signal move_requested(technology: int, domain: int, position: int)

var domain_index := -1
var append_position := 0

var _hint: Label


func configure(domain: int) -> void:
	domain_index = domain
	custom_minimum_size.y = 22
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _hint != null:
		return
	_hint = Label.new()
	_hint.text = "空闲 · 双击科技加入"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_hint.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	add_child(_hint)


# Only queue rows are recycled; the empty hint stays alive so the drop target
# never collapses to zero height between rebuilds.
func clear_rows() -> void:
	for child in get_children():
		if child == _hint:
			continue
		remove_child(child)
		child.queue_free()


func set_empty_hint(empty: bool) -> void:
	if _hint != null:
		_hint.visible = empty


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and String(data.get("type", "")) == "technology_queue_item"


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	move_requested.emit(int(data.get("technology", -1)), domain_index, append_position)
