extends VBoxContainer
class_name FamilyList

const FamilyRowScene := preload("res://scenes/ui/family_row.tscn")

signal details_requested(request: Dictionary)
signal dispatch_requested(family_handle: int, source_cell: int)

var _row_refs: Dictionary = {}
var _selected_row := ""


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "family_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(row_id)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	var active_rows := {}
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		active_rows[row_id] = true
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id)
		_apply_row(_row_refs[row_id], data)

	# 保持现存行可见，避免日更在按下和松开之间取消点击。
	for row_id in _row_refs.keys():
		if not active_rows.has(row_id):
			var row := (_row_refs[row_id] as Dictionary).get("button") as Control
			row.visible = false


func _create_row(row_id: String) -> Dictionary:
	var button := FamilyRowScene.instantiate() as Button
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_ALL
	UIAnimation.bind_hover_glow(button)
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "family", "row_id": row_id}))
	add_child(button)
	var dispatch := button.get_node("Margin/Line/DispatchButton") as Button
	dispatch.pressed.connect(func() -> void:
		var intent: Dictionary = dispatch.get_meta("dispatch", {})
		dispatch_requested.emit(int(intent.get("family_handle", 0)), int(intent.get("source_cell", -1))))
	return {"button": button, "icon": button.get_node("Margin/Line/Icon"),
		"name": button.get_node("Margin/Line/Identity/Name"),
		"meta": button.get_node("Margin/Line/Identity/Meta"),
		"prestige": button.get_node("Margin/Line/Prestige"), "dispatch": dispatch}


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func focus_selected() -> void:
	if not _row_refs.has(_selected_row):
		return
	var button := (_row_refs[_selected_row] as Dictionary).get("button") as Button
	if button != null and button.is_visible_in_tree():
		button.grab_focus()


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var button := refs.get("button") as Button
	button.visible = true
	button.set_pressed_no_signal(String(data.get("id", "")) == _selected_row)
	var dispatch := refs.get("dispatch") as Button
	dispatch.set_meta("dispatch", data)
	dispatch.disabled = not bool(data.get("can_dispatch", false))
	dispatch.tooltip_text = "从此城派遣该家族，再选择目的地" if not dispatch.disabled \
		else "仅本国城市且当地家族至少两人时可以派遣"
	(refs.get("icon") as IconBadge).set_semantic(&"family.workspace.crest", UITokens.DOSSIER_BRASS)
	(refs.get("name") as Label).text = String(data.get("name", "家族"))
	var meta := PackedStringArray(["族人 %s" % String(data.get("population", "0")),
		"产业 %s 栋" % String(data.get("owned_buildings", "0"))])
	var notable := int(data.get("notable_people", 0))
	if notable > 0:
		meta.append("名人 %d" % notable)
	var cash := String(data.get("cash_claim", ""))
	if cash != "":
		meta.append("现金 %s" % cash)
	(refs.get("meta") as Label).text = " · ".join(meta)
	var prestige := refs.get("prestige") as Label
	var p_text := String(data.get("prestige", "0"))
	prestige.text = "威望 %s" % p_text if not p_text.begins_with("威望") else p_text
	prestige.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if p_text != "0" else UITokens.DOSSIER_INK_MUTED)
	prestige.tooltip_text = "家族威望等级"
