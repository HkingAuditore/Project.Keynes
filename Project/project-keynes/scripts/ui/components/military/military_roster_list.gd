extends DossierChart

## 军事页的「当地部队」名录：一行一支部队（番号 · 归属 · 兵力），点行打开军务档案。
## 只画本格在场的野战部队；本地驻防的兵员由上方驻军条承担，不重复列一遍。

signal army_selected(handle: int)

const TouchUI := preload("res://scripts/ui/touch_ui.gd")
const ROW_HEIGHT := 27.0
const NAME_SIZE := 14
const HEADS_SIZE := 14
const TAG_SIZE := 11

var _rows: Array = []
var _hover := -1


func _init() -> void:
	super()
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_rows(rows: Array) -> void:
	_rows = rows
	_hover = -1
	var row_height := _row_height()
	custom_minimum_size = Vector2(0.0, row_height * float(_rows.size()))
	visible = not _rows.is_empty()
	_start_animation()


func row_count() -> int:
	return _rows.size()


## 行高跟着触摸档抬：桌面上 27px，触摸档取 TouchUI 的密集目标。
func _row_height() -> float:
	return maxf(ROW_HEIGHT, TouchUI.dense_units())


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover >= 0:
		_hover = -1
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion) and not (event is InputEventMouseButton):
		return
	var point: Vector2 = (event as InputEventMouseMotion).position \
		if event is InputEventMouseMotion else (event as InputEventMouseButton).position
	var index := int(floor(point.y / _row_height()))
	if index < 0 or index >= _rows.size():
		index = -1
	if event is InputEventMouseMotion:
		if index != _hover:
			_hover = index
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if index >= 0 \
				else Control.CURSOR_ARROW
			queue_redraw()
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed or index < 0:
		return
	accept_event()
	var handle := int((_rows[index] as Dictionary).get("handle", 0))
	if handle != 0:
		army_selected.emit(handle)


func _draw() -> void:
	var w := size.x
	var row_height := _row_height()
	for index in range(_rows.size()):
		var row: Dictionary = _rows[index]
		var top := row_height * float(index)
		var baseline := top + row_height * 0.5 + 5.0
		if index == _hover:
			MilitaryPaperStyle.paper_bar(self, Rect2(Vector2(0.0, top + 1.0),
				Vector2(w, row_height - 2.0)), UITokens.DOSSIER_HOVER, 1.0)
		var name := String(row.get("name", ""))
		var muted := bool(row.get("foreign", false))
		var fitted := _fit_text(name, NAME_SIZE, w * 0.5)
		_text(Vector2(0.0, baseline), fitted, NAME_SIZE,
			UITokens.DOSSIER_INK_MUTED if muted else UITokens.DOSSIER_INK, "sans_strong")
		if muted:
			# 「外」= 不是本格所属国的军队，紧跟番号；国名留在军务档案页里。
			_text(Vector2(_text_width(fitted, NAME_SIZE, "sans_strong") + 7.0,
				baseline - 1.0), "外", TAG_SIZE, UITokens.DOSSIER_OXBLOOD, "sans_strong")
		var heads := UITokens.format_compact_number_cn(float(row.get("heads", 0)), 1)
		_text(Vector2(w - 74.0, baseline), heads, HEADS_SIZE, UITokens.DOSSIER_INK,
			"numeral", HORIZONTAL_ALIGNMENT_RIGHT, 74.0)
		MilitaryPaperStyle.wobble_line(self, Vector2(0.0, top + row_height - 1.0),
			Vector2(w, top + row_height - 1.0), Color(UITokens.DOSSIER_RULE, 0.22),
			1.0, 41 + index, 0.4, 3)
