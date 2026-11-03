extends DossierChart
class_name MilitaryToggleList

## 可勾选名单：每行一枚纸贴勾选框 + 名称 + 右侧注记。整表一个控件自绘，
## 逐行点击切换并把新状态交给调用方（调用方提交命令，本控件不持状态）。
## 用于议和条款里的「交还 / 割让」占领格清单。

signal row_toggled(row_id: Variant, checked: bool)

const ROW_HEIGHT := 22.0
const ICON := 18.0
const BOX := 14.0

var checked_rows: Dictionary = {}

var _rows: Array = []
var _hover := -1


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false


func set_rows(rows: Array, checked: Dictionary) -> void:
	_rows = rows
	checked_rows = checked
	custom_minimum_size.y = ROW_HEIGHT * float(rows.size())
	visible = not rows.is_empty()
	if _hover >= rows.size():
		_hover = -1
	queue_redraw()


func checked_ids() -> Array:
	var out: Array = []
	for row in _rows:
		var row_id = row.get("id")
		if bool(checked_rows.get(row_id, false)):
			out.append(row_id)
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover >= 0:
		_hover = -1
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var index := _row_at((event as InputEventMouseMotion).position)
		if index != _hover:
			_hover = index
			tooltip_text = String(_rows[index].get("tooltip", "")) if index >= 0 else ""
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if index >= 0 \
				else Control.CURSOR_ARROW
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
			return
		var index := _row_at(button.position)
		if index < 0:
			return
		var row: Dictionary = _rows[index]
		var row_id = row.get("id")
		var next := not bool(checked_rows.get(row_id, false))
		checked_rows[row_id] = next
		row_toggled.emit(row_id, next)
		queue_redraw()
		accept_event()


func _row_at(point: Vector2) -> int:
	var index := int(floor(point.y / ROW_HEIGHT))
	return index if index >= 0 and index < _rows.size() else -1


func _draw() -> void:
	var width := size.x
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var top := ROW_HEIGHT * float(i)
		var checked := bool(checked_rows.get(row.get("id"), false))
		if i == _hover:
			draw_rect(Rect2(Vector2(0.0, top), Vector2(width, ROW_HEIGHT)), UITokens.DOSSIER_HOVER)
		var mid := top + ROW_HEIGHT * 0.5
		var box := Rect2(Vector2(2.0, mid - BOX * 0.5), Vector2(BOX, BOX))
		draw_rect(box, UITokens.DOSSIER_PAPER)
		draw_rect(box, UITokens.DOSSIER_INK_SOFT if checked else UITokens.DOSSIER_RULE,
			false, 1.0)
		if checked:
			_icon(&"action.confirm", box.grow(-2.0), UITokens.DOSSIER_OXBLOOD)
		var x := box.end.x + 6.0
		var icon_key := StringName(row.get("icon", &""))
		if icon_key != &"":
			_icon(icon_key, Rect2(Vector2(x, mid - ICON * 0.5), Vector2(ICON, ICON)),
				UITokens.DOSSIER_INK_SOFT)
			x += ICON + 4.0
		var note := String(row.get("note", ""))
		var note_width := 0.0
		if not note.is_empty():
			note_width = minf(width * 0.42, _text_width(note, 12, "sans") + 6.0)
			_text(Vector2(width - note_width, mid + 4.0), _fit_text(note, 12, note_width),
				12, UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_RIGHT, note_width)
		_text(Vector2(x, mid + 4.5), _fit_text(String(row.get("label", "")), 13,
			width - x - note_width - 8.0), 13,
			UITokens.DOSSIER_INK if checked else UITokens.DOSSIER_INK_SOFT)
