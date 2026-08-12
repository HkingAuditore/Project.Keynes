extends PanelContainer
class_name ConstructionPicker

signal page_requested(search: String, offset: int)
signal build_requested(request: Dictionary)

var _search: LineEdit
var _status: Label
var _rows: VBoxContainer
var _prev: Button
var _next: Button
var _page_label: Label
var _model: Dictionary = {}
var _model_initialized := false


func _ready() -> void:
	_search = get_node("Margin/Root/SearchRow/Search") as LineEdit
	_status = get_node("Margin/Root/Status") as Label
	_rows = get_node("Margin/Root/Rows") as VBoxContainer
	_prev = get_node("Margin/Root/Pager/Prev") as Button
	_next = get_node("Margin/Root/Pager/Next") as Button
	_page_label = get_node("Margin/Root/Pager/Page") as Label
	_search.text_submitted.connect(func(_text: String) -> void:
		page_requested.emit(_search.text, 0))
	_prev.pressed.connect(func() -> void:
		page_requested.emit(_search.text,
			maxi(0, int(_model.get("offset", 0)) - int(_model.get("limit", 32)))))
	_next.pressed.connect(func() -> void:
		page_requested.emit(_search.text,
			int(_model.get("offset", 0)) + int(_model.get("limit", 32))))
	if _model_initialized:
		_apply_model()


func set_model(model: Dictionary) -> void:
	_model = model
	_model_initialized = true
	if _rows == null:
		return
	_apply_model()


func _apply_model() -> void:
	for child in _rows.get_children():
		child.queue_free()
	if not bool(_model.get("available", false)):
		_status.text = String(_model.get("message", "只能在玩家领土内修建建筑。"))
		_search.editable = false
		_prev.disabled = true
		_next.disabled = true
		_page_label.text = ""
		return
	_search.editable = true
	_status.text = "报价为当前快照预览；实际资源与价格在经济结算边界重新原子校验。"
	var items: Array = _model.get("items", [])
	for raw in items:
		var item: Dictionary = raw
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.text = _option_text(item)
		button.disabled = not bool(item.get("eligible", false))
		button.tooltip_text = _reason_text(String(item.get("reason_code", ""))) \
			if button.disabled else "使用国库物资，缺口从当地市场购买"
		button.pressed.connect(func() -> void:
			build_requested.emit({"building_id": StringName(item.get("building_id", ""))}))
		_rows.add_child(button)
	var total := int(_model.get("total", 0))
	var offset := int(_model.get("offset", 0))
	var limit := maxi(1, int(_model.get("limit", 32)))
	_prev.disabled = offset <= 0
	_next.disabled = offset + items.size() >= total
	_page_label.text = "%d–%d / %d" % [0 if total == 0 else offset + 1,
		mini(total, offset + items.size()), total]


func set_feedback(message: String, ok: bool) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", UITokens.GOOD if ok else UITokens.RISK)


func _option_text(item: Dictionary) -> String:
	var materials := PackedStringArray()
	for raw in item.get("materials", []):
		var material: Dictionary = raw
		materials.append("%s %.2f（国库 %.2f / 市场 %.2f）" % [
			String(material.get("name", material.get("good_id", ""))),
			float(material.get("required", 0)) / 1000.0,
			float(material.get("treasury", 0)) / 1000.0,
			float(material.get("market", 0)) / 1000.0])
	var cash := float(item.get("cash_required", 0)) / 10000.0
	return "%s\n%s · 预计现金 %.2f" % [String(item.get("name", "建筑")),
		"，".join(materials), cash]


static func _reason_text(code: String) -> String:
	return {
		"construction_cell_not_owned": "目标地块不属于玩家国家",
		"construction_technology_locked": "科技尚未解锁",
		"construction_obsolete": "该建筑层级已经淘汰",
		"construction_conditions_failed": "地块条件不满足",
		"construction_resource_unavailable": "自然资源承载不足",
		"construction_materials_insufficient": "国库与当地市场建材不足",
		"construction_treasury_cash_insufficient": "国库现金不足",
		"construction_market_unavailable": "当地市场不可结算",
	}.get(code, "当前不可修建")
