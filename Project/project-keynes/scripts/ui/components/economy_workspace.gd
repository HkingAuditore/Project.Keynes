extends Control
class_name EconomyWorkspace

const MetricCardScript = preload("res://scripts/ui/components/metric_card.gd")

var _cash_card: MetricCard
var _status_label: Label
var _goods_count_label: Label
var _scroll: ScrollContainer
var _rows_box: VBoxContainer
var _empty_label: Label
var _rows: Dictionary = {}


func _ready() -> void:
	if _cash_card != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", UITokens.SPACE_MD)
	add_child(column)

	_cash_card = MetricCardScript.new()
	_cash_card.custom_minimum_size = Vector2(0.0, 78.0)
	column.add_child(_cash_card)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	_status_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_status_label.visible = false
	column.add_child(_status_label)

	var section_header := HBoxContainer.new()
	section_header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(section_header)
	var section_title := Label.new()
	section_title.text = "国库物资"
	section_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section_title.add_theme_font_override("font", UITokens.font_with_weight(650))
	section_title.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	section_title.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	section_header.add_child(section_title)
	_goods_count_label = Label.new()
	_goods_count_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_goods_count_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	section_header.add_child(_goods_count_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	column.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_scroll.add_child(_rows_box)
	_empty_label = Label.new()
	_empty_label.text = "当前国库没有非零物资"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	_empty_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	_rows_box.add_child(_empty_label)


func set_model(model: Dictionary) -> void:
	refresh_model(model)


func refresh_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	var country_available := bool(model.get("available", false))
	var treasury: Dictionary = model.get("treasury", {})
	var treasury_available := country_available and bool(treasury.get("available", false))
	var country_name := String(model.get("country_name", "玩家国家"))
	_cash_card.set_data(
		"国库现金",
		String(treasury.get("cash_text", "—")) if treasury_available else "—",
		country_name,
		UITokens.RESOURCE,
		"",
		"treasury")
	_status_label.visible = not treasury_available
	_status_label.text = String(
		treasury.get("reason", model.get("reason", "国家国库暂不可用")))
	_scroll.visible = treasury_available
	_goods_count_label.visible = treasury_available
	if not treasury_available:
		_hide_all_rows()
		return
	var goods: Array = treasury.get("goods", [])
	_goods_count_label.text = "%d 种非零物资" % goods.size()
	_apply_goods(goods)


func cash_text() -> String:
	if _cash_card == null:
		return ""
	var value_label := _cash_card.get("_value_label") as Label
	return value_label.text if value_label != null else ""


func visible_good_count() -> int:
	var count := 0
	for row_data in _rows.values():
		var row := row_data.get("control") as Control
		if row != null and row.visible:
			count += 1
	return count


func good_value_text(stable_id: String) -> String:
	var row_data: Dictionary = _rows.get(stable_id, {})
	var value_label := row_data.get("value") as Label
	return value_label.text if value_label != null else ""


func good_row_instance_id(stable_id: String) -> int:
	var row_data: Dictionary = _rows.get(stable_id, {})
	var row := row_data.get("control") as Control
	return row.get_instance_id() if row != null else 0


func _apply_goods(goods: Array) -> void:
	_hide_all_rows()
	for good_value in goods:
		var good: Dictionary = good_value
		var stable_id := String(good.get("id", ""))
		if stable_id.is_empty():
			continue
		if not _rows.has(stable_id):
			_rows[stable_id] = _make_good_row(stable_id)
		var row_data: Dictionary = _rows[stable_id]
		var row := row_data.get("control") as Control
		var icon := row_data.get("icon") as IconBadge
		var name_label := row_data.get("name") as Label
		var value_label := row_data.get("value") as Label
		row.visible = true
		row.tooltip_text = stable_id
		icon.set_semantic(StringName(good.get("icon", "system.unknown")), UITokens.RESOURCE)
		name_label.text = String(good.get("display_name", stable_id))
		value_label.text = String(good.get("quantity_text", "0"))
	_empty_label.visible = visible_good_count() == 0


func _hide_all_rows() -> void:
	for row_data in _rows.values():
		var row := row_data.get("control") as Control
		if row != null:
			row.visible = false
	if _empty_label != null:
		_empty_label.visible = true


func _make_good_row(stable_id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "TreasuryGood_%s" % stable_id
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		UITokens.CARD_BG, Color(UITokens.RESOURCE.r, UITokens.RESOURCE.g,
			UITokens.RESOURCE.b, 0.46)))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_SM)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(row)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(28.0, 28.0)
	row.add_child(icon)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_override("font", UITokens.font_with_weight(600))
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	row.add_child(name_label)
	var value_label := Label.new()
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	value_label.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	row.add_child(value_label)
	_rows_box.add_child(panel)
	return {
		"control": panel,
		"icon": icon,
		"name": name_label,
		"value": value_label,
	}
