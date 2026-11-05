extends DossierChart
class_name DossierBarList

const TouchUI := preload("res://scripts/ui/touch_ui.gd")

## 带标签的横条列表：部门产值、满足率分档、受阻原因、需求压力、城市分布等。
## 每行：[图标] 标签 | 横条（可带刻度标记） | 数值。整列自绘，可点击。
## diverging = true 时 value 取 -1..1，以中线为零点向两侧生长。

signal row_selected(row_id: Variant)

var row_height := 26.0
var label_width := 96.0
var value_width := 72.0
var diverging := false
var selectable := false
var selected_id: Variant = null

var _rows: Array = []
var _values := PackedFloat32Array()
var _from := PackedFloat32Array()
var _hover := -1
var _touch_press_active := false
var _touch_press_pos := Vector2.ZERO
var _touch_dragged := false


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS


func set_rows(rows: Array) -> void:
	_from = _blend_arrays(_from, _values, _blend)
	_rows = rows
	# 只有可点选的横条行才需要长到触摸目标；纯读数的图表保持原行高，
	# 免得把一屏能看完的十行数据撑成需要滚三屏（真机反馈「太大更难用」）。
	if selectable:
		row_height = maxf(row_height, TouchUI.min_units())
	_values = PackedFloat32Array()
	for row in rows:
		var value := float((row as Dictionary).get("value", 0.0))
		if bool((row as Dictionary).get("disabled", false)):
			_values.append(0.0)
		else:
			_values.append(clampf(value, -1.0, 1.0) if diverging else clampf(value, 0.0, 1.0))
	custom_minimum_size.y = row_height * float(rows.size())
	if _hover >= rows.size():
		_hover = -1
	_start_animation()


func row_count() -> int:
	return _rows.size()


func _gui_input(event: InputEvent) -> void:
	var is_touch_event := TouchUI.is_touch() or event.device == -1
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _touch_press_active and motion.position.distance_to(_touch_press_pos) > 10.0:
			_touch_dragged = true
			_hover = -1
			queue_redraw()
			return
		var index := int(floor(motion.position.y / row_height))
		index = index if index >= 0 and index < _rows.size() else -1
		if index != _hover:
			_hover = index
			tooltip_text = String(_rows[index].get("tooltip", "")) if index >= 0 else ""
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
				if selectable and index >= 0 else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton and selectable:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if is_touch_event:
			if button.pressed:
				_touch_press_active = true
				_touch_press_pos = button.position
				_touch_dragged = false
				_hover = _row_at(button.position)
				queue_redraw()
				return
			if not _touch_press_active:
				return
			var dragged := _touch_dragged or button.position.distance_to(_touch_press_pos) > 10.0
			_touch_press_active = false
			_touch_dragged = false
			var index := _row_at(button.position)
			_hover = -1
			queue_redraw()
			if not dragged and index >= 0:
				row_selected.emit(_rows[index].get("id"))
			return
		if button.pressed:
			var index := _row_at(button.position)
			if index >= 0:
				_hover = index
				row_selected.emit(_rows[index].get("id"))
				accept_event()


func _row_at(point: Vector2) -> int:
	var index := int(floor(point.y / maxf(row_height, 1.0)))
	return index if index >= 0 and index < _rows.size() else -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover >= 0:
		_hover = -1
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var values := _blend_arrays(_from, _values, _blend)
	var bar_left := label_width
	var bar_right := maxf(bar_left + 20.0, w - value_width - 8.0)
	var bar_width := bar_right - bar_left
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var top := row_height * float(i)
		var is_disabled := bool(row.get("disabled", false))
		var is_selected: bool = selected_id != null and row.get("id") == selected_id \
			and not is_disabled
		if is_selected:
			draw_rect(Rect2(Vector2(0.0, top + 1.0), Vector2(w, row_height - 2.0)),
				UITokens.DOSSIER_SELECTED)
			draw_rect(Rect2(Vector2(0.0, top + 3.0), Vector2(3.0, row_height - 6.0)),
				UITokens.DOSSIER_OXBLOOD)
		elif i == _hover and selectable and not is_disabled:
			draw_rect(Rect2(Vector2(0.0, top + 1.0), Vector2(w, row_height - 2.0)),
				UITokens.DOSSIER_HOVER)
		var ink: Color = UITokens.DOSSIER_INK_MUTED if is_disabled else UITokens.DOSSIER_INK
		var baseline := top + row_height * 0.5 + 5.0
		var x := 6.0
		var icon_key := StringName(row.get("icon", &""))
		if icon_key != &"":
			_icon(icon_key, Rect2(Vector2(x, top + row_height * 0.5 - 8.0), Vector2(16.0, 16.0)),
				row.get("color", UITokens.DOSSIER_INK_SOFT))
			x += 21.0
		_text(Vector2(x, baseline), _fit_text(String(row.get("label", "")), 13,
			bar_left - x - 6.0), 13, ink, "sans")
		var bar_y := top + row_height * 0.5 - 4.0
		var track := Rect2(Vector2(bar_left, bar_y), Vector2(bar_width, 8.0))
		_rounded_bar(track, UITokens.DOSSIER_TRACK, 2.0)
		var color: Color = row.get("color", UITokens.DOSSIER_BRASS)
		var value := values[i] * _grow if i < values.size() else 0.0
		if diverging:
			var mid := bar_left + bar_width * 0.5
			var length := bar_width * 0.5 * absf(value)
			var fill_color := UITokens.DOSSIER_VERDIGRIS if value >= 0.0 else UITokens.DOSSIER_OXBLOOD
			if row.has("color"):
				fill_color = color
			_rounded_bar(Rect2(Vector2(mid if value >= 0.0 else mid - length, bar_y),
				Vector2(length, 8.0)), fill_color, 2.0)
			draw_line(Vector2(mid, bar_y - 3.0), Vector2(mid, bar_y + 11.0),
				UITokens.DOSSIER_INK_MUTED, 1.0)
		else:
			_rounded_bar(Rect2(track.position, Vector2(bar_width * value, 8.0)), color, 2.0)
		var marker := float(row.get("marker", -1.0))
		if marker >= 0.0:
			var mx := bar_left + bar_width * clampf(marker, 0.0, 1.0)
			draw_line(Vector2(mx, bar_y - 4.0), Vector2(mx, bar_y + 12.0),
				UITokens.DOSSIER_INK, 2.0)
		var value_color = UITokens.DOSSIER_INK_MUTED if is_disabled \
			else row.get("text_color", UITokens.DOSSIER_INK)
		_text(Vector2(bar_right + 8.0, baseline), _fit_text(String(row.get("text", "")), 12,
			value_width), 12, value_color, "sans_strong",
			HORIZONTAL_ALIGNMENT_RIGHT, value_width)
		if i < _rows.size() - 1:
			draw_line(Vector2(0.0, top + row_height - 0.5), Vector2(w, top + row_height - 0.5),
				Color(UITokens.DOSSIER_RULE, 0.18), 1.0)
