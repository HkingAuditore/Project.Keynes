extends DossierChart
class_name DossierHeatGrid

## 物资热力网格：按分组排列的方格，底色深浅表示短缺（暗红）或过剩（铜绿），
## 右上角刻度表示价格相对成本锚的偏离。整张网格自绘，点击方格发出 cell_selected。

signal cell_selected(cell_id: String)

const TILE_MIN_WIDTH := 96.0
const TILE_HEIGHT := 42.0
const GAP := 4.0
const HEADER_HEIGHT := 22.0

var selected_id := ""
var _groups: Array = []
var _cells: Array = []
var _layout: Array = []
var _hover := -1


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP


## groups: [{id, name}]；cells: [{id, name, group, heat(-1..1), price_index, tooltip}]
func set_cells(groups: Array, cells: Array) -> void:
	_groups = groups
	_cells = cells
	_relayout()
	_start_animation()


func cell_count() -> int:
	return _cells.size()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_relayout()
		NOTIFICATION_MOUSE_EXIT:
			if _hover >= 0:
				_hover = -1
				queue_redraw()


func _relayout() -> void:
	_layout.clear()
	var width := maxf(TILE_MIN_WIDTH, size.x)
	var columns := maxi(1, int(floor((width + GAP) / (TILE_MIN_WIDTH + GAP))))
	var tile_width := (width - GAP * float(columns - 1)) / float(columns)
	var y := 0.0
	var by_group := {}
	for i in range(_cells.size()):
		var group := String(_cells[i].get("group", ""))
		if not by_group.has(group):
			by_group[group] = []
		(by_group[group] as Array).append(i)
	var headers: Array = []
	for group in _groups:
		var members: Array = by_group.get(String(group.id), [])
		if members.is_empty():
			continue
		headers.append({"y": y, "name": String(group.name), "count": members.size()})
		y += HEADER_HEIGHT
		for k in range(members.size()):
			var column := k % columns
			var row := k / columns
			_layout.append({"index": members[k], "rect": Rect2(
				Vector2(float(column) * (tile_width + GAP), y + float(row) * (TILE_HEIGHT + GAP)),
				Vector2(tile_width, TILE_HEIGHT))})
		y += float(ceili(float(members.size()) / float(columns))) * (TILE_HEIGHT + GAP) + 6.0
	set_meta("headers", headers)
	if absf(custom_minimum_size.y - y) > 0.5:
		custom_minimum_size.y = y
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit((event as InputEventMouseMotion).position)
		if hit != _hover:
			_hover = hit
			tooltip_text = String(_cells[hit].get("tooltip", "")) if hit >= 0 else ""
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hit >= 0 \
				else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT and _hover >= 0:
			cell_selected.emit(String(_cells[_hover].get("id", "")))
			accept_event()


func _hit(point: Vector2) -> int:
	for entry in _layout:
		if (entry.rect as Rect2).has_point(point):
			return int(entry.index)
	return -1


func _draw() -> void:
	for header in get_meta("headers", []):
		var y := float(header.y)
		_text(Vector2(0.0, y + 15.0), "%s · %d" % [String(header.name), int(header.count)], 12,
			UITokens.DOSSIER_INK_SOFT, "sans_strong")
		draw_line(Vector2(0.0, y + HEADER_HEIGHT - 3.0), Vector2(size.x, y + HEADER_HEIGHT - 3.0),
			UITokens.DOSSIER_RULE, 1.0)
	for entry in _layout:
		var index := int(entry.index)
		var cell: Dictionary = _cells[index]
		var rect: Rect2 = entry.rect
		var heat := clampf(float(cell.get("heat", 0.0)), -1.0, 1.0) * _grow
		draw_rect(rect, UITokens.DOSSIER_PAPER_DEEP)
		if absf(heat) > 0.01:
			var tone := UITokens.DOSSIER_OXBLOOD if heat > 0.0 else UITokens.DOSSIER_VERDIGRIS
			draw_rect(rect, Color(tone, 0.12 + 0.62 * absf(heat)))
		var strong := absf(heat) > 0.55
		var ink := UITokens.DOSSIER_PAPER if strong else UITokens.DOSSIER_INK
		var muted := Color(UITokens.DOSSIER_PAPER, 0.85) if strong else UITokens.DOSSIER_INK_MUTED
		var icon_key := IconCatalog.good_semantic(String(cell.get("id", "")))
		var icon_rect := Rect2(rect.position + Vector2(5.0, 5.0), Vector2(18.0, 18.0))
		if icon_key != &"system.unknown":
			IconCatalog.draw_icon(self, icon_key, icon_rect)
		var name_left := 28.0 if icon_key != &"system.unknown" else 6.0
		_text(rect.position + Vector2(name_left, 17.0), _fit_text(String(cell.get("name", "")), 12,
			rect.size.x - name_left - 4.0), 12, ink, "sans_strong")
		var status := String(cell.get("status", ""))
		_text(rect.position + Vector2(6.0, 34.0), _fit_text(status, 11, rect.size.x - 10.0), 11, muted)
		var price_index := float(cell.get("price_index", 1.0))
		var deviation := clampf(price_index - 1.0, -1.0, 1.0)
		if absf(deviation) >= 0.05:
			var corner := rect.position + Vector2(rect.size.x - 6.0, 6.0)
			var tri := PackedVector2Array([corner, corner + Vector2(-8.0, 0.0), corner + Vector2(0.0, 8.0)]) \
				if deviation > 0.0 else PackedVector2Array([corner + Vector2(0.0, 8.0),
					corner + Vector2(-8.0, 8.0), corner + Vector2(0.0, 0.0)])
			draw_colored_polygon(tri, ink)
		var outline := UITokens.DOSSIER_RULE
		var width := 1.0
		if String(cell.get("id", "")) == selected_id:
			outline = UITokens.DOSSIER_INK
			width = 2.0
		elif index == _hover:
			outline = UITokens.DOSSIER_BRASS
			width = 2.0
		draw_rect(rect, outline, false, width)
