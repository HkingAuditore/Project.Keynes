extends Control
class_name AnnualProgressRail

## 右侧章节刻度轨。
##
## 旧版是一列 166px 宽、10 项 14px 的按钮，选中项只有 3px 红线——看起来像草稿目录。
## 这里只留一条发丝竖线加十个刻度：当前章刻度变长变朱红并标出章号，
## 悬停显示章名。它同时就是目录，点击即可跳章。

signal chapter_requested(index: int)

var _titles: PackedStringArray = PackedStringArray()
var _current := 0
var _hover := -1
var _tick_top := 180.0
var _tick_bottom := 260.0
var _on_desk := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size.x = AnnualReportTokens.RAIL_WIDTH


## 刻度轨现在浮在长纸右侧的桌面上，深底需要反过来用浅墨与铜金。
func set_on_desk(value: bool) -> void:
	_on_desk = value
	queue_redraw()


func set_chapters(titles: PackedStringArray) -> void:
	_titles = titles
	queue_redraw()


func set_current(index: int) -> void:
	if _current == index:
		return
	_current = index
	queue_redraw()


func _ink(alpha: float) -> Color:
	var base: Color = UITokens.CHRONICLE_LIGHT_INK if _on_desk else UITokens.CHRONICLE_INK
	return Color(base.r, base.g, base.b, alpha)


func _accent(alpha: float) -> Color:
	var base: Color = UITokens.CHRONICLE_BRASS if _on_desk else UITokens.CHRONICLE_RED
	return Color(base.r, base.g, base.b, alpha)


func _soft(alpha: float) -> Color:
	var base: Color = UITokens.CHRONICLE_LIGHT_MUTED if _on_desk else UITokens.CHRONICLE_MUTED
	return Color(base.r, base.g, base.b, alpha)


func _draw() -> void:
	var count: int = _titles.size()
	if count < 2:
		return
	var h: float = size.y
	_tick_top = maxf(96.0, h * 0.24)
	_tick_bottom = minf(h - 96.0, h * 0.80)
	var line_x: float = 22.0
	var span: float = _tick_bottom - _tick_top
	draw_line(Vector2(line_x, _tick_top), Vector2(line_x, _tick_bottom), _ink(0.38 if _on_desk else 0.30), 2.4, true)
	var font := UITokens.annual_font("label")
	for i in count:
		var y: float = _tick_top + span * float(i) / float(count - 1)
		var active: bool = i == _current
		var hovered: bool = i == _hover
		var length: float = 18.0 if active else (13.0 if hovered else 8.0)
		var color: Color = _accent(0.95) if active else _ink(0.42 if not hovered else 0.72)
		draw_line(Vector2(line_x, y), Vector2(line_x + length, y), color, 3.2 if active else 1.7, true)
		if active or hovered:
			var text := "%02d  %s" % [i + 1, _titles[i]]
			var alpha: float = 1.0 if active else 0.7
			draw_string(font, Vector2(line_x + length + 8.0, y + 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13,
				_accent(alpha) if active else _soft(alpha))


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var index := _index_at(event.position.y)
	if index >= 0:
		preload("res://scripts/ui/ui_audio_feedback.gd").play_for(self, &"page")
		chapter_requested.emit(index)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER or what == NOTIFICATION_MOUSE_EXIT:
		_hover = -1
		queue_redraw()


func _process(_delta: float) -> void:
	if not visible or _titles.size() < 2:
		return
	var local := get_local_mouse_position()
	var inside: bool = Rect2(Vector2.ZERO, size).has_point(local)
	var index: int = _index_at(local.y) if inside else -1
	if index != _hover:
		_hover = index
		queue_redraw()


func _index_at(y: float) -> int:
	var count: int = _titles.size()
	if count < 2:
		return -1
	var span: float = _tick_bottom - _tick_top
	if span <= 0.0:
		return -1
	var slot: float = span / float(count - 1)
	var index := int(round((y - _tick_top) / slot))
	if index < 0 or index >= count:
		return -1
	if absf(y - (_tick_top + slot * float(index))) > maxf(10.0, slot * 0.45):
		return -1
	return index
