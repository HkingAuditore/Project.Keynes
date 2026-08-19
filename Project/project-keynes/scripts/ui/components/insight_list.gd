extends VBoxContainer
class_name InsightList

const InsightRowScene := preload("res://scenes/ui/insight_row.tscn")
const ROW_CAPACITY := 4

var _rows: Array[HBoxContainer] = []
var _icons: Array[IconBadge] = []
var _labels: Array[Label] = []
var _items_applied := false


func _ready() -> void:
	add_theme_constant_override("separation", UITokens.SPACE_SM)
	if _rows.is_empty():
		_index_existing_rows()
		if _rows.is_empty():
			_ensure_capacity(ROW_CAPACITY)
	if not _items_applied:
		for row in _rows:
			row.visible = false


func set_items(items: Array) -> void:
	if _rows.is_empty():
		_index_existing_rows()
	_ensure_capacity(maxi(items.size(), ROW_CAPACITY))
	update_items(items)
	_items_applied = true


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


func _index_existing_rows() -> void:
	_rows.clear()
	_icons.clear()
	_labels.clear()
	for child in get_children():
		var row := child as HBoxContainer
		if row == null:
			continue
		var icon := row.get_node_or_null("Icon") as IconBadge
		var label := row.get_node_or_null("Label") as Label
		if icon == null or label == null:
			continue
		_rows.append(row)
		_icons.append(icon)
		_labels.append(label)


func _ensure_capacity(count: int) -> void:
	while _rows.size() < count:
		var row := InsightRowScene.instantiate() as HBoxContainer
		var icon := row.get_node("Icon") as IconBadge
		var label := row.get_node("Label") as Label
		add_child(row)
		_rows.append(row)
		_icons.append(icon)
		_labels.append(label)
