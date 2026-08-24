extends PanelContainer
class_name TechnologyQueueRow

const DragPreviewScene := preload("res://scenes/ui/technology_drag_preview.tscn")

signal move_requested(technology: int, domain: int, position: int)
signal remove_requested(technology: int)
signal selected_requested(technology: int)

var technology_index := -1
var domain_index := -1
var queue_position := -1
var display_name := ""

var _accent: Color = UITokens.ACCENT
var _order: Label
var _state: Label
var _name: Label
var _progress: ProgressBar
var _remove: Button


# Rows are created only when the queue composition actually changes; daily
# progress updates go through update_dynamic() so nothing is reallocated.
func setup(technology: int, domain: int, position: int, title: String,
		accent: Color) -> void:
	technology_index = technology
	domain_index = domain
	queue_position = position
	display_name = title
	_accent = accent
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "%s\n拖动可调整顺序或改换领域" % title
	_order = get_node_or_null("Row/Order") as Label
	_state = get_node_or_null("Row/State") as Label
	_name = get_node_or_null("Row/NameLabel") as Label
	_progress = get_node_or_null("Row/Progress") as ProgressBar
	_remove = get_node_or_null("Row/Remove") as Button
	if _order == null or _state == null or _name == null \
			or _progress == null or _remove == null:
		push_error("TechnologyQueueRow 必须通过 technology_queue_row.tscn 实例化。")
		return
	_order.text = "%d" % (position + 1)
	_name.text = title
	_progress.max_value = 100.0
	IconButton.apply(_remove, &"action.close", 10, "移出研究队列")
	_remove.pressed.connect(func() -> void: remove_requested.emit(technology_index))
	gui_input.connect(_on_gui_input)


func update_dynamic(state: int, fraction: float) -> void:
	if _state == null:
		return
	IconButton.apply_to_label(_state, IconCatalog.technology_state_semantic(state), 11)
	_state.add_theme_color_override("font_color",
		UITokens.WARN if state >= 4 else _accent.lerp(UITokens.ARCHIVE_INK, 0.50))
	_progress.value = clampf(fraction, 0.0, 1.0) * 100.0


func _get_drag_data(_at_position: Vector2) -> Variant:
	if technology_index < 0:
		return null
	var preview := DragPreviewScene.instantiate() as Label
	preview.text = display_name
	set_drag_preview(preview)
	return {
		"type": "technology_queue_item",
		"technology": technology_index,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and String(data.get("type", "")) == "technology_queue_item"


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	move_requested.emit(int(data.get("technology", -1)), domain_index, queue_position)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			selected_requested.emit(technology_index)
