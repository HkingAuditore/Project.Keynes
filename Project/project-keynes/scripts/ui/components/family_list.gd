extends VBoxContainer
class_name FamilyList

const FamilyRowScene := preload("res://scenes/ui/family_row.tscn")

signal details_requested(request: Dictionary)

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
	for refs_value in _row_refs.values():
		var refs: Dictionary = refs_value
		var button := refs.get("button") as Button
		if button != null:
			button.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(row_id)
		_apply_row(_row_refs[row_id], data)


func _create_row(row_id: String) -> Dictionary:
	var button := FamilyRowScene.instantiate() as Button
	button.toggle_mode = true
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "family", "row_id": row_id}))
	add_child(button)
	return {"button": button, "icon": button.get_node("Margin/Line/Icon"),
		"name": button.get_node("Margin/Line/Identity/Name"),
		"meta": button.get_node("Margin/Line/Identity/Meta"),
		"prestige": button.get_node("Margin/Line/Prestige")}


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var button := refs.get("button") as Button
	button.visible = true
	(refs.get("icon") as IconBadge).set_semantic(&"family.house", UITokens.DOSSIER_INK_SOFT)
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
	prestige.text = String(data.get("prestige", "0"))
	prestige.tooltip_text = "威望"
