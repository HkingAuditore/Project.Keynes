extends VBoxContainer
class_name CohortList

const CohortRowScene := preload("res://scenes/ui/cohort_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _row_data: Dictionary = {}
var _selected_row := ""


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	_row_data.clear()
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "cohort_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id, data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for refs in _row_refs.values():
		var panel := (refs as Dictionary).get("panel") as PanelContainer
		if panel != null:
			panel.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id, data)
		_row_data[row_id] = data.duplicate(true)
		_apply_row(row_id, _row_refs[row_id], data)


func _create_row(row_id: String, data: Dictionary) -> Dictionary:
	var panel := CohortRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Body/Button") as Button
	button.toggle_mode = true
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "cohort", "row_id": row_id,
			"profession_id": String((_row_data.get(row_id, {}) as Dictionary) \
				.get("profession_id", ""))}))
	var living_icon := panel.get_node("Body/Button/Header/LivingIcon") as IconBadge
	living_icon.mouse_filter = Control.MOUSE_FILTER_STOP
	var refs := {"panel": panel, "button": button,
		"icon": panel.get_node("Body/Button/Header/Icon"),
		"living_icon": living_icon, "name": panel.get_node("Body/Button/Header/Identity/Name"),
		"population": panel.get_node("Body/Button/Header/Population"),
		"wealth": panel.get_node("Body/Button/Header/Balance/Wealth"),
		"net": panel.get_node("Body/Button/Header/Balance/Net")}
	_apply_row(row_id, refs, data)
	return refs


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func _apply_row(_row_id: String, refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	(refs.get("icon") as IconBadge).set_semantic(
		StringName(data.get("icon", &"ecology.growth")), accent)
	var living_accent: Color = data.get("living_accent", UITokens.TEXT_MUTED)
	var living_badge := refs.get("living_icon") as IconBadge
	living_badge.set_semantic(
		StringName(data.get("living_icon", &"action.history")), living_accent)
	var living_text := String(data.get("living_standard", "待评估"))
	living_badge.tooltip_text = "%s · 满意度 %s" % [
		living_text,
		String(data.get("satisfaction", "—"))]
	var name_label := refs.get("name") as Label
	name_label.text = String(data.get("name", "阶层"))
	name_label.tooltip_text = String(data.get("status", ""))
	(refs.get("population") as Label).text = String(data.get("population", ""))
	(refs.get("wealth") as Label).text = String(data.get("wealth", "")).trim_prefix("人均 ")
	var card_net_label := refs.get("net") as Label
	card_net_label.text = String(data.get("net", "—"))
	card_net_label.add_theme_color_override(
		"font_color", UITokens.GOOD if bool(data.get("net_positive", true)) else UITokens.RISK)
