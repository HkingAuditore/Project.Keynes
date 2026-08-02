extends VBoxContainer
class_name FamilyList

const FamilyRowScene := preload("res://scenes/ui/family_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}


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
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "family", "row_id": row_id}))
	add_child(button)
	return {"button": button, "icon": button.get_node("Margin/Line/Icon"),
		"name": button.get_node("Margin/Line/Name")}


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.ACCENT)
	var button := refs.get("button") as Button
	button.visible = true
	(refs.get("icon") as IconBadge).set_semantic(&"family.house", accent)
	(refs.get("name") as Label).text = String(data.get("name", "家族"))
