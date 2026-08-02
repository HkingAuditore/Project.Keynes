extends VBoxContainer
class_name MarketList

const MarketRowScene := preload("res://scenes/ui/market_row.tscn")
const MarketDetailRowScene := preload("res://scenes/ui/market_detail_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _expanded: Dictionary = {}


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_expanded.clear()
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


func set_expanded(row_id: String, expanded: bool) -> void:
	if not _row_refs.has(row_id):
		return
	_expanded[row_id] = expanded
	var refs: Dictionary = _row_refs[row_id]
	if expanded:
		_sync_details(refs, refs.get("detail_rows", []))
	var chevron := refs.get("chevron") as Button
	if chevron != null:
		IconButton.apply(chevron,
			&"action.chevron_down" if expanded else &"action.chevron_right",
			IconButton.SMALL, "展开 / 折叠", true, expanded)
	var details := refs.get("details") as Control
	if details.visible != expanded:
		details.visible = expanded


func is_expanded(row_id: String) -> bool:
	return bool(_expanded.get(row_id, false))


func _create_row(row_id: String) -> Dictionary:
	var panel := MarketRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "good", "row_id": row_id}))
	var chevron := panel.get_node("Body/Button/Header/Chevron") as Button
	chevron.toggled.connect(func(expanded: bool) -> void: set_expanded(row_id, expanded))
	var refs := {"panel": panel, "button": button, "chevron": chevron,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"name": panel.get_node("Body/Button/Header/Identity/Name"),
		"stock": panel.get_node("Body/Button/Header/Identity/Stock"),
		"price": panel.get_node("Body/Button/Header/PriceBox/Price"),
		"delta": panel.get_node("Body/Button/Header/PriceBox/Delta"),
		"risk": panel.get_node("Body/Button/Header/Risk"),
		"details": panel.get_node("Body/Details"), "detail_refs": {},
		"detail_rows": [], "applied": {}}
	return refs


func _sync_details(refs: Dictionary, rows: Array) -> void:
	var details := refs.get("details") as VBoxContainer
	var detail_refs: Dictionary = refs.get("detail_refs", {})
	var active_details: Dictionary = {}
	for raw in rows:
		var data: Dictionary = raw
		var detail_id := String(data.get("id", "detail_%d" % detail_refs.size()))
		active_details[detail_id] = true
		if not detail_refs.has(detail_id):
			detail_refs[detail_id] = _create_detail(details)
		_apply_detail(detail_refs[detail_id], data)
	for detail_id in detail_refs.keys():
		if active_details.has(detail_id):
			continue
		var detail: Dictionary = detail_refs[detail_id]
		var root := detail.get("root") as Control
		if root.visible:
			root.visible = false
	refs["detail_refs"] = detail_refs


func _create_detail(parent: VBoxContainer) -> Dictionary:
	var margin := MarketDetailRowScene.instantiate() as MarginContainer
	parent.add_child(margin)
	return {"root": margin, "name": margin.get_node("Line/Name"),
		"value": margin.get_node("Line/Value")}


func _apply_row(row_id: String, refs: Dictionary, data: Dictionary) -> void:
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
		else (UITokens.RISK if delta.begins_with("-") else UITokens.TEXT_MUTED)
	if not applied.has("delta_color") or applied["delta_color"] != delta_color:
		delta_label.add_theme_color_override("font_color", delta_color)
	var risk := String(data.get("risk", ""))
	var risk_label := refs.get("risk") as Label
	if risk_label.text != risk:
		risk_label.text = risk
	# 折叠行只缓存最新详情；展开时才创建/更新详情节点，避免日更遍历整张商品明细表。
	var detail_rows: Array = data.get("detail_rows", [])
	refs["detail_rows"] = detail_rows
	set_expanded(row_id, bool(_expanded.get(row_id, false)))
	applied["accent"] = accent
	applied["icon"] = icon_key
	applied["delta_color"] = delta_color
	refs["applied"] = applied


func _apply_detail(refs: Dictionary, data: Dictionary) -> void:
	var root := refs.get("root") as Control
	var detail_visible := bool(data.get("visible", true))
	if root.visible != detail_visible:
		root.visible = detail_visible
	var name_text := String(data.get("name", ""))
	var name_label := refs.get("name") as Label
	if name_label.text != name_text:
		name_label.text = name_text
	var value_text := String(data.get("value", ""))
	var value_label := refs.get("value") as Label
	if value_label.text != value_text:
		value_label.text = value_text
