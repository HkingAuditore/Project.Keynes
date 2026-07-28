extends PanelContainer
class_name TechnologyQueueRow

signal move_requested(technology: int, domain: int, position: int)
signal remove_requested(technology: int)

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
	var style := UITokens.inset_panel_style(
		Color(0.068, 0.058, 0.045, 0.94), Color(accent.r, accent.g, accent.b, 0.72),
		UITokens.RADIUS_SM)
	style.content_margin_left = UITokens.SPACE_XS
	style.content_margin_right = UITokens.SPACE_XS
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	style.shadow_size = 0
	add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	add_child(row)
	_order = Label.new()
	_order.text = "%d" % (position + 1)
	_order.custom_minimum_size.x = 11.0
	_order.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_order.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	row.add_child(_order)
	_state = Label.new()
	_state.custom_minimum_size.x = 14.0
	_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_state)
	_name = Label.new()
	_name.text = title
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_name.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	row.add_child(_name)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(42.0, 6.0)
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress.show_percentage = false
	_progress.max_value = 100.0
	row.add_child(_progress)
	_remove = Button.new()
	_remove.focus_mode = Control.FOCUS_NONE
	_remove.custom_minimum_size = Vector2(20.0, 18.0)
	IconButton.apply(_remove, &"action.close", 10, "移出研究队列")
	_remove.pressed.connect(func() -> void: remove_requested.emit(technology_index))
	row.add_child(_remove)


func update_dynamic(state: int, fraction: float) -> void:
	if _state == null:
		return
	IconButton.apply_to_label(_state, IconCatalog.technology_state_semantic(state), 11)
	_state.add_theme_color_override("font_color",
		UITokens.WARN if state >= 4 else _accent.lerp(UITokens.TEXT_MAIN, 0.50))
	_progress.value = clampf(fraction, 0.0, 1.0) * 100.0


func _get_drag_data(_at_position: Vector2) -> Variant:
	if technology_index < 0:
		return null
	var preview := Label.new()
	preview.text = display_name
	preview.add_theme_stylebox_override("normal", UITokens.inset_panel_style(
		Color(0.06, 0.05, 0.04, 0.96), UITokens.BRASS_HIGHLIGHT))
	set_drag_preview(preview)
	return {
		"type": "technology_queue_item",
		"technology": technology_index,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and String(data.get("type", "")) == "technology_queue_item"


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	move_requested.emit(int(data.get("technology", -1)), domain_index, queue_position)
