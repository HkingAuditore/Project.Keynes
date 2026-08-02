extends VBoxContainer
class_name InsightList

const InsightRowScene := preload("res://scenes/ui/insight_row.tscn")

const ROW_CAPACITY := 4

var _rows: Array[HBoxContainer] = []
var _icons: Array[IconBadge] = []
var _labels: Array[Label] = []


func set_items(items: Array) -> void:
	for child in get_children():
		child.queue_free()
	_rows.clear()
	_icons.clear()
	_labels.clear()
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	var capacity := maxi(ROW_CAPACITY, items.size())
	for i in range(capacity):
		var row := InsightRowScene.instantiate() as HBoxContainer
		var icon := row.get_node("Icon") as IconBadge
		var label := row.get_node("Label") as Label
		add_child(row)
		_rows.append(row)
		_icons.append(icon)
		_labels.append(label)
	update_items(items)


func update_items(items: Array) -> void:
	for i in range(_rows.size()):
		var visible_row := i < items.size()
		_rows[i].visible = visible_row
		if not visible_row:
			continue
		var data: Dictionary = items[i]
		var accent: Color = data.get("accent", UITokens.ACCENT)
		_icons[i].set_semantic(
			StringName(data.get("icon", &"summary.overview")), accent)
		_labels[i].text = String(data.get("text", ""))
		_labels[i].add_theme_color_override("font_color", UITokens.TEXT_MAIN)
