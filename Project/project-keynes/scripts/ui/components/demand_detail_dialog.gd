extends Control
class_name DemandDetailDialog

const ProductCellScene := preload("res://scenes/ui/demand_product_cell.tscn")
const ValueCellScene := preload("res://scenes/ui/demand_value_cell.tscn")

signal closed()

var _cohort_label: Label
var _rows_grid: GridContainer
var _empty_label: Label
var _total_quantity_label: Label
var _total_cost_label: Label


func _ready() -> void:
	if _rows_grid != null:
		return
	_cohort_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/CohortLabel") as Label
	_rows_grid = get_node_or_null("Center/Dialog/Body/Scroll/RowsGrid") as GridContainer
	_empty_label = get_node_or_null("Center/Dialog/Body/Scroll/RowsGrid/EmptyLabel") as Label
	_total_quantity_label = get_node_or_null("Center/Dialog/Body/Totals/Quantity") as Label
	_total_cost_label = get_node_or_null("Center/Dialog/Body/Totals/Cost") as Label
	var icon := get_node_or_null("Center/Dialog/Body/TitleRow/Icon") as IconBadge
	var close_button := get_node_or_null("Center/Dialog/Body/TitleRow/CloseButton") as Button
	var backdrop_close := get_node_or_null("BackdropClose") as Button
	if _cohort_label == null or _rows_grid == null or _empty_label == null \
			or _total_quantity_label == null or _total_cost_label == null \
			or icon == null or close_button == null or backdrop_close == null:
		push_error("DemandDetailDialog 必须通过 demand_detail_dialog.tscn 实例化。")
		return
	icon.set_semantic(&"economy.resource", UITokens.RESOURCE)
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_dialog)
	backdrop_close.pressed.connect(close_dialog)


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


func _clear_rows() -> void:
	for child in _rows_grid.get_children():
		if child != _empty_label:
			_rows_grid.remove_child(child)
			child.queue_free()


func _add_demand_row(row: Dictionary) -> void:
	_add_product_cell(row)
	_add_table_label(_rows_grid, String(row.get("quantity", "—")), 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MAIN, false, 46.0)
	_add_table_label(_rows_grid, String(row.get("price", "—")), 112.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.TEXT_MUTED, false, 46.0)
	_add_table_label(_rows_grid, String(row.get("daily_cost", "—")), 120.0,
		HORIZONTAL_ALIGNMENT_RIGHT, UITokens.RESOURCE, false, 46.0)


func _add_product_cell(row: Dictionary) -> void:
	var cell := ProductCellScene.instantiate() as MarginContainer
	_rows_grid.add_child(cell)
	var name_label := cell.get_node("Labels/Name") as Label
	name_label.text = String(row.get("name", "未知商品"))
	var attribution := cell.get_node("Labels/Attribution") as Label
	attribution.text = _attribution_text(row)


func _attribution_text(row: Dictionary) -> String:
	if not bool(row.get("attribution_available", false)):
		return "变化归因待下次结算"
	var wealth := int(row.get("wealth_delta_raw", 0))
	var price := int(row.get("price_delta_raw", 0))
	if wealth == 0 and price == 0:
		return "与上次结算相同"
	return "财富 %s · 价格 %s" % [_signed_quantity(wealth), _signed_quantity(price)]


func _signed_quantity(value: int) -> String:
	return "%s%.3f" % ["+" if value > 0 else ("−" if value < 0 else ""),
		absf(float(value)) / 1000.0]


func _add_group_header(group: Dictionary, row_count: int) -> void:
	var group_title := String(group.get("name", "其他"))
	var satisfaction := String(group.get("satisfaction", ""))
	if not satisfaction.is_empty():
		group_title += " · " + satisfaction
	_add_table_label(_rows_grid, group_title, 188.0,
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
	var label := ValueCellScene.instantiate() as Label
	label.text = text
	label.custom_minimum_size = Vector2(minimum_width, minimum_height)
	label.horizontal_alignment = alignment
	label.add_theme_color_override("font_color", color)
	if strong:
		label.add_theme_font_override("font", UITokens.font_with_weight(650))
	parent.add_child(label)
