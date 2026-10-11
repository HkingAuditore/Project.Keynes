extends ScrollContainer
class_name TechnologyAvailableView

# Research desk: queued, researchable and pending tech.* cards drawn by one
# TechnologyAvailableList. Applications never appear here — they auto-enable
# outside the queue.

signal technology_selected(index: int)
signal technology_activated(index: int)
signal show_in_tree_requested(index: int)
signal enqueue_requested(index: int)
signal remove_requested(index: int)

var _list: TechnologyAvailableList


func _ready() -> void:
	if _list != null:
		return
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = get_node_or_null("List") as TechnologyAvailableList
	if _list == null:
		push_error("TechnologyAvailableView 必须通过 technology_available_view.tscn 实例化。")
		return
	_list.technology_selected.connect(func(index: int) -> void: technology_selected.emit(index))
	_list.technology_activated.connect(func(index: int) -> void: technology_activated.emit(index))
	_list.show_in_tree_requested.connect(func(index: int) -> void:
		show_in_tree_requested.emit(index))
	_list.enqueue_requested.connect(func(index: int) -> void: enqueue_requested.emit(index))
	_list.remove_requested.connect(func(index: int) -> void: remove_requested.emit(index))
	get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _list.queue_redraw())


func set_catalog(definitions: Array, domains: Array,
		research_definition_count: int = -1, era_names: Dictionary = {}) -> void:
	if _list == null:
		_ready()
	if definitions.is_empty():
		return
	_list.set_catalog(definitions, domains, research_definition_count \
		if research_definition_count >= 0 else definitions.size(), era_names)


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	if _list == null:
		_ready()
	_list.patch_states(states, progress)


func set_queue_info(order: Dictionary, eta: Dictionary) -> void:
	if _list != null:
		_list.set_queue_info(order, eta)


func select_technology(index: int) -> void:
	if _list != null:
		_list.select_technology(index)


func selected_technology() -> int:
	return _list.selected_technology() if _list != null else -1


func list_canvas() -> TechnologyAvailableList:
	return _list


func available_report() -> Dictionary:
	return _list.report() if _list != null else {}
