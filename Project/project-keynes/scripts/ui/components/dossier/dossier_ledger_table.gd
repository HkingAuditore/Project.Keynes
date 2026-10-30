extends DossierChart
class_name DossierLedgerTable

## 卷宗账簿表：可排序表头、行悬停/选中、行内操作图标，整表一个控件自绘。
## 只绘制落在外层 ScrollContainer 可视区内的行，表头在滚动时吸顶。
##
## columns: [{id, label, width, expand, kind, align, optional, sortable, tooltip}]
##   kind: text | number | money | bar | diverging | stacked | actions
##   money 列右对齐，并在数字前画一枚金币（单位不写成字，见 MoneyDisplay）。
## rows: [{id, tooltip, muted, cells: {col_id: {text, value, sort, color, segments, icon, sub}}}]

signal row_selected(row_id: Variant)
signal row_action(row_id: Variant, action_id: String)

const HEADER_HEIGHT := 28.0
const ACTION_SIZE := 22.0

var row_height := 30.0
var selected_id: Variant = null
var sort_column := ""
var sort_descending := true
var empty_text := "暂无记录"

var _columns: Array = []
var _visible_columns: Array = []
var _rows: Array = []
var _order := PackedInt32Array()
var _hover_row := -1
var _hover_header := -1
var _hover_action := ""
var _scroll: ScrollContainer
var _sort_keys: Array = []


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false


func set_columns(columns: Array, default_sort: String = "", descending: bool = true) -> void:
	_columns = columns
	if sort_column.is_empty():
		sort_column = default_sort
		sort_descending = descending
	_layout_columns()


func set_rows(rows: Array) -> void:
	_rows = rows
	_sort()
	custom_minimum_size.y = HEADER_HEIGHT + row_height * float(maxi(1, rows.size())) + 4.0
	if _hover_row >= rows.size():
		_hover_row = -1
	_start_animation()


func row_count() -> int:
	return _rows.size()


func sorted_ids() -> Array:
	var ids: Array = []
	for index in _order:
		ids.append(_rows[index].get("id"))
	return ids


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE:
			_attach_scroll()
		NOTIFICATION_EXIT_TREE:
			_detach_scroll()
		NOTIFICATION_RESIZED:
			_layout_columns()
		NOTIFICATION_MOUSE_EXIT:
			_hover_row = -1
			_hover_header = -1
			_hover_action = ""
			queue_redraw()


func _attach_scroll() -> void:
	var node := get_parent()
	while node != null and not (node is ScrollContainer):
		node = node.get_parent()
	_scroll = node as ScrollContainer
	if _scroll != null:
		var bar := _scroll.get_v_scroll_bar()
		if not bar.value_changed.is_connected(_on_scrolled):
			bar.value_changed.connect(_on_scrolled)


func _detach_scroll() -> void:
	if _scroll != null and is_instance_valid(_scroll):
		var bar := _scroll.get_v_scroll_bar()
		if bar.value_changed.is_connected(_on_scrolled):
			bar.value_changed.disconnect(_on_scrolled)
	_scroll = null


func _on_scrolled(_value: float) -> void:
	queue_redraw()


func _layout_columns() -> void:
	var available := maxf(160.0, size.x)
	var keep: Array = _columns.duplicate()
	while true:
		var total := 0.0
		for column in keep:
			total += float(column.get("width", 80.0)) if not bool(column.get("expand", false)) \
				else float(column.get("min_width", 120.0))
		if total <= available:
			break
		var dropped := false
		for i in range(keep.size() - 1, -1, -1):
			if bool(keep[i].get("optional", false)):
				keep.remove_at(i)
				dropped = true
				break
		if not dropped:
			break
	var fixed := 0.0
	var expanders := 0
	for column in keep:
		if bool(column.get("expand", false)):
			expanders += 1
		else:
			fixed += float(column.get("width", 80.0))
	var extra := maxf(0.0, available - fixed)
	var x := 0.0
	_visible_columns.clear()
	for column in keep:
		var width := float(column.get("width", 80.0))
		if bool(column.get("expand", false)):
			width = maxf(float(column.get("min_width", 120.0)), extra / float(maxi(1, expanders)))
		_visible_columns.append({"column": column, "x": x, "width": width})
		x += width
	queue_redraw()


func _sort() -> void:
	_order = PackedInt32Array()
	for i in range(_rows.size()):
		_order.append(i)
	if sort_column.is_empty():
		return
	_sort_keys.clear()
	for row in _rows:
		_sort_keys.append(_sort_key(row, sort_column))
	var indices: Array = Array(_order)
	indices.sort_custom(_compare_rows)
	_order = PackedInt32Array(indices)
	_sort_keys.clear()


func _compare_rows(a: int, b: int) -> bool:
	var ka = _sort_keys[a]
	var kb = _sort_keys[b]
	if typeof(ka) == typeof(kb) and ka != kb:
		return ka > kb if sort_descending else ka < kb
	return a < b


func _sort_key(row: Dictionary, column_id: String) -> Variant:
	var cell = (row.get("cells", {}) as Dictionary).get(column_id, null)
	if cell is Dictionary:
		if cell.has("sort"):
			return cell.sort
		if cell.has("value"):
			return float(cell.value)
		return String(cell.get("text", ""))
	return cell if cell != null else 0.0


func _visible_range() -> Vector2:
	if _scroll == null or not is_instance_valid(_scroll):
		return Vector2(0.0, size.y)
	var top := _scroll.get_global_rect().position.y - global_position.y
	return Vector2(maxf(0.0, top), minf(size.y, top + _scroll.size.y))


func _header_y() -> float:
	return clampf(_visible_range().x, 0.0, maxf(0.0, size.y - HEADER_HEIGHT - row_height))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
			return
		_update_hover(button.position)
		if _hover_header >= 0:
			var column: Dictionary = _visible_columns[_hover_header].column
			if bool(column.get("sortable", true)) and String(column.get("kind", "text")) != "actions":
				var column_id := String(column.id)
				if sort_column == column_id:
					sort_descending = not sort_descending
				else:
					sort_column = column_id
					sort_descending = String(column.get("kind", "text")) != "text"
				_sort()
				queue_redraw()
			accept_event()
			return
		if _hover_row >= 0:
			var row: Dictionary = _rows[_order[_hover_row]]
			if not _hover_action.is_empty():
				row_action.emit(row.get("id"), _hover_action)
			else:
				row_selected.emit(row.get("id"))
			accept_event()


func _update_hover(point: Vector2) -> void:
	var header_y := _header_y()
	var header := -1
	var row_index := -1
	var action := ""
	if point.y >= header_y and point.y < header_y + HEADER_HEIGHT:
		for i in range(_visible_columns.size()):
			var entry: Dictionary = _visible_columns[i]
			if point.x >= float(entry.x) and point.x < float(entry.x) + float(entry.width):
				header = i
				break
	else:
		var index := int(floor((point.y - HEADER_HEIGHT) / row_height))
		if index >= 0 and index < _order.size() and point.y >= HEADER_HEIGHT:
			row_index = index
			action = _action_at(_rows[_order[index]], point, HEADER_HEIGHT + row_height * float(index))
	if header != _hover_header or row_index != _hover_row or action != _hover_action:
		_hover_header = header
		_hover_row = row_index
		_hover_action = action
		if header >= 0:
			var column: Dictionary = _visible_columns[header].column
			tooltip_text = String(column.get("tooltip", column.get("label", "")))
		elif row_index >= 0:
			var row: Dictionary = _rows[_order[row_index]]
			tooltip_text = _action_tooltip(row, action) if not action.is_empty() \
				else String(row.get("tooltip", ""))
		else:
			tooltip_text = ""
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
			if header >= 0 or row_index >= 0 else Control.CURSOR_ARROW
		queue_redraw()


func _action_rects(row: Dictionary, top: float) -> Array:
	var rects: Array = []
	for entry in _visible_columns:
		if String(entry.column.get("kind", "")) != "actions":
			continue
		var actions: Array = row.get("actions", [])
		var x := float(entry.x) + float(entry.width) - 6.0
		for i in range(actions.size() - 1, -1, -1):
			x -= ACTION_SIZE
			rects.append({"id": String(actions[i].id), "rect": Rect2(Vector2(x,
				top + (row_height - ACTION_SIZE) * 0.5), Vector2(ACTION_SIZE, ACTION_SIZE)),
				"icon": StringName(actions[i].icon), "tooltip": String(actions[i].get("tooltip", ""))})
			x -= 4.0
	return rects


func _action_at(row: Dictionary, point: Vector2, top: float) -> String:
	for entry in _action_rects(row, top):
		if (entry.rect as Rect2).has_point(point):
			return String(entry.id)
	return ""


func _action_tooltip(row: Dictionary, action_id: String) -> String:
	for action in row.get("actions", []):
		if String(action.id) == action_id:
			return String(action.get("tooltip", ""))
	return ""


func _draw() -> void:
	var w := size.x
	var visible := _visible_range()
	if _rows.is_empty():
		_text(Vector2(0.0, HEADER_HEIGHT + 20.0), empty_text, 13, UITokens.DOSSIER_INK_MUTED,
			"sans", HORIZONTAL_ALIGNMENT_CENTER, w)
	var first := maxi(0, int(floor((visible.x - HEADER_HEIGHT) / row_height)))
	var last := mini(_order.size(), int(ceil((visible.y - HEADER_HEIGHT) / row_height)) + 1)
	for position_index in range(first, last):
		var row: Dictionary = _rows[_order[position_index]]
		var top := HEADER_HEIGHT + row_height * float(position_index)
		if position_index % 2 == 1:
			draw_rect(Rect2(Vector2(0.0, top), Vector2(w, row_height)), UITokens.DOSSIER_PAPER_SHADE)
		var is_selected: bool = selected_id != null and row.get("id") == selected_id
		if is_selected:
			draw_rect(Rect2(Vector2(0.0, top), Vector2(w, row_height)), UITokens.DOSSIER_SELECTED)
			draw_rect(Rect2(Vector2(0.0, top + 3.0), Vector2(3.0, row_height - 6.0)),
				UITokens.DOSSIER_OXBLOOD)
		elif position_index == _hover_row:
			draw_rect(Rect2(Vector2(0.0, top), Vector2(w, row_height)), UITokens.DOSSIER_HOVER)
		var muted := bool(row.get("muted", false))
		for entry in _visible_columns:
			var cell = (row.get("cells", {}) as Dictionary).get(String(entry.column.id), null)
			_draw_cell(entry, cell, row, top, muted, position_index == _hover_row)
		draw_line(Vector2(0.0, top + row_height - 0.5), Vector2(w, top + row_height - 0.5),
			Color(UITokens.DOSSIER_RULE, 0.25), 1.0)
	_draw_header(_header_y(), w)


func _draw_header(y: float, w: float) -> void:
	draw_rect(Rect2(Vector2(0.0, y), Vector2(w, HEADER_HEIGHT)), UITokens.DOSSIER_PAPER)
	draw_line(Vector2(0.0, y + HEADER_HEIGHT - 1.0), Vector2(w, y + HEADER_HEIGHT - 1.0),
		UITokens.DOSSIER_RULE_STRONG, 1.5)
	for i in range(_visible_columns.size()):
		var entry: Dictionary = _visible_columns[i]
		var column: Dictionary = entry.column
		var x := float(entry.x)
		var width := float(entry.width)
		if i == _hover_header:
			draw_rect(Rect2(Vector2(x, y), Vector2(width, HEADER_HEIGHT - 2.0)), UITokens.DOSSIER_HOVER)
		var label := String(column.get("label", ""))
		var active := String(column.id) == sort_column
		var align := _align(column)
		var color := UITokens.DOSSIER_OXBLOOD if active else UITokens.DOSSIER_INK_SOFT
		var text_width := width - 16.0
		_text(Vector2(x + 8.0, y + 18.0), _fit_text(label, 12, text_width - 10.0, "sans_strong"),
			12, color, "sans_strong", align, text_width - (10.0 if active and align == HORIZONTAL_ALIGNMENT_RIGHT else 0.0))
		if active:
			var ax := x + width - 10.0 if align == HORIZONTAL_ALIGNMENT_RIGHT \
				else x + 12.0 + _text_width(label, 12, "sans_strong")
			var ay := y + 13.0
			var tri := PackedVector2Array([Vector2(ax - 4.0, ay - 2.0), Vector2(ax + 4.0, ay - 2.0),
				Vector2(ax, ay + 3.0)]) if sort_descending else PackedVector2Array([
				Vector2(ax - 4.0, ay + 3.0), Vector2(ax + 4.0, ay + 3.0), Vector2(ax, ay - 2.0)])
			draw_colored_polygon(tri, color)


func _align(column: Dictionary) -> HorizontalAlignment:
	match String(column.get("align", "")):
		"right":
			return HORIZONTAL_ALIGNMENT_RIGHT
		"center":
			return HORIZONTAL_ALIGNMENT_CENTER
		"left":
			return HORIZONTAL_ALIGNMENT_LEFT
	match String(column.get("kind", "text")):
		"number", "money", "bar", "diverging", "stacked":
			return HORIZONTAL_ALIGNMENT_RIGHT
	return HORIZONTAL_ALIGNMENT_LEFT


func _draw_cell(entry: Dictionary, cell, row: Dictionary, top: float, muted: bool,
		hovered: bool) -> void:
	var column: Dictionary = entry.column
	var x := float(entry.x) + 8.0
	var width := float(entry.width) - 16.0
	var kind := String(column.get("kind", "text"))
	var baseline := top + row_height * 0.5 + 5.0
	var ink := UITokens.DOSSIER_INK_MUTED if muted else UITokens.DOSSIER_INK
	if kind == "actions":
		for action in _action_rects(row, top):
			var rect: Rect2 = action.rect
			var active := hovered and String(action.id) == _hover_action
			if active:
				draw_rect(rect, UITokens.DOSSIER_HOVER)
			draw_rect(rect, UITokens.DOSSIER_RULE if not active else UITokens.DOSSIER_BRASS, false, 1.0)
			_icon(StringName(action.icon), rect.grow(-4.0),
				UITokens.DOSSIER_OXBLOOD if active else UITokens.DOSSIER_INK_SOFT)
		return
	if cell == null:
		return
	var data: Dictionary = cell if cell is Dictionary else {"text": str(cell)}
	var text := String(data.get("text", ""))
	var color: Color = data.get("color", ink)
	match kind:
		"bar", "diverging", "stacked":
			var text_w := minf(width * 0.42, 70.0)
			var bar_w := maxf(10.0, width - text_w - 6.0)
			var bar_rect := Rect2(Vector2(x, top + row_height * 0.5 - 4.0), Vector2(bar_w, 8.0))
			_rounded_bar(bar_rect, UITokens.DOSSIER_TRACK, 2.0)
			if kind == "bar":
				var fill := clampf(float(data.get("value", 0.0)), 0.0, 1.0) * _grow
				_rounded_bar(Rect2(bar_rect.position, Vector2(bar_w * fill, 8.0)),
					data.get("bar_color", UITokens.DOSSIER_BRASS), 2.0)
			elif kind == "diverging":
				var value := clampf(float(data.get("value", 0.0)), -1.0, 1.0) * _grow
				var mid := bar_rect.position.x + bar_w * 0.5
				var length := bar_w * 0.5 * absf(value)
				_rounded_bar(Rect2(Vector2(mid if value >= 0.0 else mid - length, bar_rect.position.y),
					Vector2(length, 8.0)), UITokens.DOSSIER_VERDIGRIS if value >= 0.0
					else UITokens.DOSSIER_OXBLOOD, 2.0)
				draw_line(Vector2(mid, bar_rect.position.y - 2.0), Vector2(mid, bar_rect.end.y + 2.0),
					UITokens.DOSSIER_INK_MUTED, 1.0)
			else:
				var segments: Array = data.get("segments", [])
				var total := 0.0
				for segment in segments:
					total += maxf(0.0, float(segment.value))
				var sx := bar_rect.position.x
				if total > 0.0:
					for segment in segments:
						var sw := bar_w * maxf(0.0, float(segment.value)) / total * _grow
						draw_rect(Rect2(Vector2(sx, bar_rect.position.y), Vector2(sw, 8.0)),
							segment.get("color", UITokens.DOSSIER_BRASS))
						sx += sw
			_text(Vector2(x + bar_w + 6.0, baseline), _fit_text(text, 12, text_w), 12, color,
				"sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, text_w)
		_:
			var tx := x
			var icon_key := StringName(data.get("icon", &""))
			if icon_key != &"":
				_icon(icon_key, Rect2(Vector2(tx, top + row_height * 0.5 - 8.0), Vector2(16.0, 16.0)),
					data.get("icon_color", UITokens.DOSSIER_INK_SOFT))
				tx += 21.0
			elif data.has("dot"):
				draw_circle(Vector2(tx + 4.0, top + row_height * 0.5), 4.0, data.dot)
				tx += 13.0
			var sub := String(data.get("sub", ""))
			var align := _align(column)
			var font_kind := "sans_strong" if kind == "number" or kind == "money" \
				or bool(data.get("strong", false)) else "sans"
			if kind == "money":
				# 金额列：数字前画一枚金币，单位不再写成字（见 MoneyDisplay）。
				var room := x + width - tx
				var shown := _fit_text(text, 13, room - MoneyDisplay.slot_width(13), font_kind)
				if align == HORIZONTAL_ALIGNMENT_RIGHT:
					_money_text_right(x + width, baseline, shown, 13, color, font_kind)
				else:
					_money_text(Vector2(tx, baseline), shown, 13, color, font_kind)
				return
			if sub.is_empty():
				_text(Vector2(tx, baseline), _fit_text(text, 13, x + width - tx, font_kind), 13, color,
					font_kind, align, x + width - tx)
			else:
				var main_width := _text_width(text, 13, font_kind)
				var fitted := _fit_text(text, 13, x + width - tx, font_kind)
				_text(Vector2(tx, baseline), fitted, 13, color, font_kind, align, x + width - tx)
				if align == HORIZONTAL_ALIGNMENT_LEFT and main_width + 10.0 < x + width - tx:
					_text(Vector2(tx + main_width + 6.0, baseline), _fit_text(sub, 11,
						x + width - tx - main_width - 6.0), 11, UITokens.DOSSIER_INK_MUTED)
