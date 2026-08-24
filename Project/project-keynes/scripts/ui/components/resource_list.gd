extends VBoxContainer
class_name ResourceList

const ResourceRowScene := preload("res://scenes/ui/resource_row.tscn")

signal details_requested(request: Dictionary)

var _row_refs: Dictionary = {}
var _selected_row := ""


func set_rows(rows: Array) -> void:
	for child in get_children():
		child.queue_free()
	_row_refs.clear()
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", "resource_%d" % _row_refs.size()))
		_row_refs[row_id] = _create_row(data)
	update_rows(rows)


func update_rows(rows: Array) -> void:
	for row_id in _row_refs.keys():
		var refs: Dictionary = _row_refs[row_id]
		var panel := refs.get("panel") as PanelContainer
		if panel != null:
			panel.visible = false
	for raw in rows:
		var data: Dictionary = raw
		var row_id := String(data.get("id", ""))
		if row_id.is_empty():
			continue
		if not _row_refs.has(row_id):
			_row_refs[row_id] = _create_row(data)
		_apply_row(_row_refs[row_id], data)


func _create_row(data: Dictionary) -> Dictionary:
	var panel := ResourceRowScene.instantiate() as PanelContainer
	add_child(panel)
	var button := panel.get_node("Button") as Button
	button.toggle_mode = true
	button.pressed.connect(func() -> void: details_requested.emit(
		{"kind": "resource", "row_id": String(data.get("id", ""))}))
	var refs := {
		"panel": panel,
		"button": button,
		"icon": panel.get_node("Button/Margin/Line/Icon"),
		"name": panel.get_node("Button/Margin/Line/Name"),
		"density": panel.get_node("Button/Margin/Line/Density"),
		"value": panel.get_node("Button/Margin/Line/Value"),
		"delta": panel.get_node("Button/Margin/Line/Delta"),
	}
	_apply_row(refs, data)
	return refs


func set_selected(row_id: String) -> void:
	_selected_row = row_id
	for key in _row_refs.keys():
		var refs: Dictionary = _row_refs[key]
		(refs.get("button") as Button).set_pressed_no_signal(String(key) == row_id)


func _apply_row(refs: Dictionary, data: Dictionary) -> void:
	var accent: Color = data.get("accent", UITokens.RESOURCE)
	var panel := refs.get("panel") as PanelContainer
	panel.visible = bool(data.get("visible", true))
	var icon := refs.get("icon") as IconBadge
	icon.set_semantic(StringName(data.get("icon", &"economy.resource")), accent)
	var name_label := refs.get("name") as Label
	name_label.text = String(data.get("name", "资源"))
	var density_label := refs.get("density") as Label
	density_label.text = String(data.get("density", ""))
	density_label.add_theme_color_override("font_color", accent.lerp(UITokens.ARCHIVE_INK, 0.18))
	var value_label := refs.get("value") as Label
	value_label.text = String(data.get("value", ""))
	var delta_label := refs.get("delta") as Label
	delta_label.text = String(data.get("delta", ""))
	var delta_text := delta_label.text
	delta_label.add_theme_color_override(
		"font_color",
		UITokens.GOOD if delta_text.contains("+") else (UITokens.RISK if delta_text.contains("-") else UITokens.ARCHIVE_INK_MUTED)
	)
