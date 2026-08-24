extends VBoxContainer
class_name MarketList

const MarketRowScene := preload("res://scenes/ui/market_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _selected_row := ""


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	update_rows(rows)


func update_rows(rows: Array) -> void:
	var active_rows: Dictionary = {}
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		active_rows[row_id] = true
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id)
		_apply_row(row_id, _row_refs[row_id], data)
	for row_id in _row_refs.keys():
		if active_rows.has(row_id):
			continue
		var refs: Dictionary = _row_refs[row_id]
		var panel := refs.get("panel") as PanelContainer
		if panel != null and panel.visible:
			panel.visible = false


func _create_row(row_id: String) -> Dictionary:
	var panel := MarketRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.toggle_mode = true
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "good", "row_id": row_id}))
	var refs := {"panel": panel, "button": button,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"name": panel.get_node("Body/Button/Header/Identity/Name"),
		"stock": panel.get_node("Body/Button/Header/Identity/Stock"),
		"price": panel.get_node("Body/Button/Header/PriceBox/Price"),
		"delta": panel.get_node("Body/Button/Header/PriceBox/Delta"),
		"risk": panel.get_node("Body/Button/Header/Risk"),
		"applied": {}}
	return refs


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func _apply_row(_row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var applied: Dictionary = refs.get("applied", {})
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var panel := refs.get("panel") as PanelContainer
	var row_visible := bool(data.get("visible", true))
	if panel.visible != row_visible:
		panel.visible = row_visible
	var icon_key := String(data.get("icon", "resource"))
	if not applied.has("icon") or applied["icon"] != icon_key \
			or not applied.has("accent") or applied["accent"] != accent:
		(refs.get("icon") as IconBadge).set_semantic(StringName(icon_key), accent)
	var name_text := String(data.get("name", "商品"))
	var name_label := refs.get("name") as Label
	if name_label.text != name_text:
		name_label.text = name_text
	var stock_text := String(data.get("stock", ""))
	var stock_label := refs.get("stock") as Label
	if stock_label.text != stock_text:
		stock_label.text = stock_text
	var price_text := String(data.get("price", ""))
	var price_label := refs.get("price") as Label
	if price_label.text != price_text:
		price_label.text = price_text
	var delta := String(data.get("delta", "—"))
	var delta_label := refs.get("delta") as Label
	if delta_label.text != delta:
		delta_label.text = delta
	var delta_color := UITokens.GOOD if delta.begins_with("+") \
		else (UITokens.RISK if delta.begins_with("-") else UITokens.ARCHIVE_INK_MUTED)
	if not applied.has("delta_color") or applied["delta_color"] != delta_color:
		delta_label.add_theme_color_override("font_color", delta_color)
	var risk := String(data.get("risk", ""))
	var risk_label := refs.get("risk") as Label
	if risk_label.text != risk:
		risk_label.text = risk
	applied["accent"] = accent
	applied["icon"] = icon_key
	applied["delta_color"] = delta_color
	refs["applied"] = applied
