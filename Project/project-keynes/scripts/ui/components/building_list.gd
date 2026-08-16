extends VBoxContainer
class_name BuildingList

const BuildingRowScene := preload("res://scenes/ui/building_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _selected_row := ""


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "building_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id, data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for refs in _row_refs.values():
		((refs as Dictionary).get("panel") as Control).visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id, data)
		_apply_row(row_id, _row_refs[row_id], data)


func _create_row(row_id: String, data: Dictionary) -> Dictionary:
	var panel := BuildingRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.toggle_mode = true
	button.pressed.connect(func() -> void:
		details_requested.emit({"kind": "building", "row_id": row_id}))
	var refs := {
		"panel": panel, "button": button,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"name": panel.get_node("Body/Button/Header/Identity/NameRow/Name"),
		"state_icon": panel.get_node("Body/Button/Header/Identity/NameRow/StateIcon"),
		"owner": panel.get_node("Body/Button/Header/Identity/Owner"),
		"count": panel.get_node("Body/Button/Header/Count"),
		"profit_label": panel.get_node("Body/Button/Header/ProfitBox/Label"),
		"profit": panel.get_node("Body/Button/Header/ProfitBox/Value"),
	}
	_apply_row(row_id, refs, data)
	return refs


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func _apply_row(_row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	(refs.panel as Control).visible = bool(data.get("visible", true))
	(refs.icon as IconBadge).set_semantic(
		StringName(data.get("icon", &"economy.building")), accent)
	(refs.name as Label).text = String(data.get("name", "建筑"))
	(refs.owner as Label).text = String(data.get("owner", ""))
	(refs.count as Label).text = String(data.get("count", ""))
	(refs.profit_label as Label).text = String(data.get("profit_label", "利润"))
	(refs.profit as Label).text = String(data.get("profit", ""))
	(refs.profit as Label).add_theme_color_override("font_color", accent)
	var state: Dictionary = data.get("state_summary", {})
	var state_accent: Color = state.get("accent", UITokens.WARN)
	(refs.state_icon as IconBadge).set_semantic(StringName(state.get("icon", &"")), state_accent)
	(refs.state_icon as Control).tooltip_text = String(state.get("label", ""))
