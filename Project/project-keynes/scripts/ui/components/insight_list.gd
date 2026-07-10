extends VBoxContainer
class_name InsightList

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
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UITokens.SPACE_SM)
		var icon := IconBadge.new()
		icon.custom_minimum_size = Vector2(24.0, 24.0)
		row.add_child(icon)
		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
		row.add_child(label)
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
		_icons[i].set_icon(String(data.get("icon", "overview")), accent)
		_labels[i].text = String(data.get("text", ""))
		_labels[i].add_theme_color_override("font_color", UITokens.TEXT_MAIN)
