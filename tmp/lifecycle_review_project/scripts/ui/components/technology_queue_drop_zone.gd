extends VBoxContainer
class_name TechnologyQueueDropZone

signal move_requested(technology: int, domain: int, position: int)

var domain_index := -1
var append_position := 0

var _hint: Label


func configure(domain: int) -> void:
	domain_index = domain
	if _hint != null:
		return
	_hint = get_node_or_null("Hint") as Label
	if _hint == null:
		push_error("TechnologyQueueDropZone 必须通过 technology_queue_drop_zone.tscn 实例化。")


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
