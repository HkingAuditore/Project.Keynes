extends Control
class_name DemandDetailDialog

signal closed()

var _cohort_label: Label
var _rows_grid: GridContainer
var _empty_label: Label
var _total_quantity_label: Label
var _total_cost_label: Label


func _ready() -> void:
	if _rows_grid != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_dialog()


func show_details(details: Dictionary) -> void:
	if _rows_grid == null:
		_ready()
	_cohort_label.text = String(details.get("cohort_name", "阶层"))
	_total_quantity_label.text = "%s 单位/人/日" % String(details.get("total_quantity", "—"))
	_total_cost_label.text = "%s/人/日" % String(details.get("total_daily_cost", "—"))
	_clear_rows()
	var visible_count := 0
	var groups: Array = details.get("groups", [])
	if groups.is_empty():
		for raw in details.get("rows", []):
			var row: Dictionary = raw
			if not bool(row.get("visible", true)):
				continue
			_add_demand_row(row)
			visible_count += 1
	else:
		for raw_group in groups:
			var group: Dictionary = raw_group
			var visible_rows: Array = (group.get("rows", []) as Array).filter(
				func(row: Dictionary) -> bool: return bool(row.get("visible", true)))
			if visible_rows.is_empty():
				continue
			_add_group_header(group, visible_rows.size())
			for raw_row in visible_rows:
				_add_demand_row(raw_row)
				visible_count += 1
	_empty_label.visible = visible_count == 0
	visible = true
	UIAnimation.crossfade(self, UITokens.ANIM_FAST)


func close_dialog() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_dialog()
		get_viewport().set_input_as_handled()


func _build_dialog() -> void:
	var backdrop := Button.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.focus_mode = Control.FOCUS_NONE
	backdrop.mouse_default_cursor_shape = Control.CURSOR_ARROW
	var backdrop_style := StyleBoxFlat.new()
	backdrop_style.bg_color = Color(0.012, 0.010, 0.008, 0.76)
	for state in ["normal", "hover", "pressed", "focus"]:
		backdrop.add_theme_stylebox_override(state, backdrop_style)
	backdrop.pressed.connect(close_dialog)
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640.0, 500.0)
	panel.add_theme_stylebox_override("panel", UITokens.panel_style(
		Color(0.038, 0.034, 0.029, 0.99), UITokens.RADIUS_MD,
		Color(UITokens.RESOURCE.r, UITokens.RESOURCE.g, UITokens.RESOURCE.b, 0.72)))
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	panel.add_child(margin)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(body)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(title_row)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(32.0, 32.0)
	icon.set_icon("resource", UITokens.RESOURCE)
	title_row.add_child(icon)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	title_row.add_child(titles)
	var title := Label.new()
	title.text = "消费需求明细"
	title.add_theme_font_override("font", UITokens.font_with_weight(700))
	title.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	title.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	titles.add_child(title)
	_cohort_label = Label.new()
	_cohort_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_cohort_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	titles.add_child(_cohort_label)
	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(34.0, 34.0)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.tooltip_text = "关闭"
	IconBadge.apply_to_button(close_button, "close", 14)
	close_button.pressed.connect(close_dialog)
	title_row.add_child(close_button)

	var header := GridContainer.new()
	header.columns = 4
	header.add_theme_constant_override("h_separation", UITokens.SPACE_MD)
	body.add_child(header)
	_add_table_label(header, "商品", 188.0, HORIZONTAL_ALIGNMENT_LEFT, UITokens.TEXT_MUTED, true)
	_add_table_label(header, "数量/人/日", 112.0, HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, true)
	_add_table_label(header, "本地单价", 112.0, HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, true)
	_add_table_label(header, "支出/人/日", 120.0, HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, true)
	body.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 292.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_rows_grid = GridContainer.new()
	_rows_grid.columns = 4
	_rows_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_grid.add_theme_constant_override("h_separation", UITokens.SPACE_MD)
	_rows_grid.add_theme_constant_override("v_separation", UITokens.SPACE_SM)
	scroll.add_child(_rows_grid)

	_empty_label = Label.new()
	_empty_label.text = "当前没有消费需求"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_rows_grid.add_child(_empty_label)

	body.add_child(HSeparator.new())
	var totals := HBoxContainer.new()
	totals.add_theme_constant_override("separation", UITokens.SPACE_LG)
	body.add_child(totals)
	var total_title := Label.new()
	total_title.text = "合计"
	total_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total_title.add_theme_font_override("font", UITokens.font_with_weight(650))
	total_title.add_theme_color_override("font_color", UITokens.RESOURCE)
	totals.add_child(total_title)
	_total_quantity_label = Label.new()
	_total_quantity_label.custom_minimum_size.x = 150.0
	_total_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_total_quantity_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	totals.add_child(_total_quantity_label)
	_total_cost_label = Label.new()
	_total_cost_label.custom_minimum_size.x = 150.0
	_total_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_total_cost_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_total_cost_label.add_theme_color_override("font_color", UITokens.RESOURCE)
	totals.add_child(_total_cost_label)


func _clear_rows() -> void:
	for child in _rows_grid.get_children():
		if child != _empty_label:
			_rows_grid.remove_child(child)
			child.queue_free()


func _add_demand_row(row: Dictionary) -> void:
	_add_product_cell(row)
	_add_table_label(_rows_grid, String(row.get("quantity", "—")), 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MAIN, false, 34.0)
	_add_table_label(_rows_grid, String(row.get("price", "—")), 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, false, 34.0)
	_add_table_label(_rows_grid, String(row.get("daily_cost", "—")), 120.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.RESOURCE, false, 34.0)


func _add_product_cell(row: Dictionary) -> void:
	var cell := MarginContainer.new()
	cell.custom_minimum_size = Vector2(188.0, 34.0)
	cell.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	_rows_grid.add_child(cell)
	var name_label := Label.new()
	name_label.text = String(row.get("name", "未知商品"))
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	cell.add_child(name_label)


func _add_group_header(group: Dictionary, row_count: int) -> void:
	_add_table_label(_rows_grid, String(group.get("name", "其他")), 188.0,
		HORIZONTAL_ALIGNMENT_LEFT, UITokens.RESOURCE, true, 30.0)
	_add_table_label(_rows_grid, "", 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, false, 30.0)
	_add_table_label(_rows_grid, "", 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, false, 30.0)
	_add_table_label(_rows_grid, "%d 种商品" % row_count, 120.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, false, 30.0)


func _add_table_label(
	parent: Container,
	text: String,
	minimum_width: float,
	alignment: HorizontalAlignment,
	color: Color,
	strong: bool = false,
	minimum_height: float = 26.0
) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(minimum_width, minimum_height)
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", color)
	if strong:
		label.add_theme_font_override("font", UITokens.font_with_weight(650))
	parent.add_child(label)
