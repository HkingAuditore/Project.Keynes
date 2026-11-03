extends DossierChart
class_name DossierChapterNav

## 卷宗章节索引签：一排书页索引标签，选中项为暗红签条。
## 宽度不足以放下文字时自动只显示图标（悬停显示章节名与问题）。

signal chapter_selected(chapter_id: String)

const HEIGHT := 48.0
const ICON := 28.0
const FONT_SIZE := UITokens.FONT_SMALL
const TouchUI := preload("res://scripts/ui/touch_ui.gd")

var chapters: Array = []
var current := ""
var icon_only := false
## 触摸档下把索引签抬到 44dp（88 设计像素）；桌面档恒等于 HEIGHT。
var _height := HEIGHT
var _rects: Array = []
var _hover := -1
# The indicator slides between tab indices, not pixels, so a relayout during the
# slide (e.g. a sibling appearing) cannot leave it stretched over the wrong tab.
var _from_index := -1
var _to_index := -1
var _slide := 1.0
var _indicator_tween: Tween


func _init() -> void:
	super()
	_height = maxf(HEIGHT, TouchUI.min_units())
	custom_minimum_size = Vector2(240.0, _height)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_chapters(p_chapters: Array, p_current: String) -> void:
	chapters = p_chapters
	select(p_current, false)


func select(chapter_id: String, animate: bool = true) -> void:
	current = chapter_id
	_relayout()
	var target := _index_of(chapter_id)
	if _indicator_tween != null and _indicator_tween.is_valid():
		_indicator_tween.kill()
	if not animate or not is_inside_tree() or _to_index < 0 or target < 0 \
			or target == _to_index:
		_from_index = target
		_to_index = target
		_slide = 1.0
		queue_redraw()
		return
	_from_index = _to_index if _slide >= 0.5 else _from_index
	_to_index = target
	_slide = 0.0
	_indicator_tween = create_tween()
	_indicator_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_indicator_tween.tween_method(_set_slide, _slide, 1.0, UITokens.ANIM_MED)


func _set_slide(value: float) -> void:
	_slide = value
	queue_redraw()


func _index_of(chapter_id: String) -> int:
	for i in range(chapters.size()):
		if String(chapters[i].id) == chapter_id:
			return i
	return -1


func _indicator_rect() -> Rect2:
	if _to_index < 0 or _to_index >= _rects.size():
		return Rect2()
	var to: Rect2 = _rects[_to_index]
	if _from_index < 0 or _from_index >= _rects.size() or _slide >= 1.0:
		return to
	var from: Rect2 = _rects[_from_index]
	return Rect2(from.position.lerp(to.position, _slide), from.size.lerp(to.size, _slide))


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_relayout()
		NOTIFICATION_MOUSE_EXIT:
			if _hover >= 0:
				_hover = -1
				queue_redraw()


func _relayout() -> void:
	_height = maxf(HEIGHT, TouchUI.min_units())
	if absf(custom_minimum_size.y - _height) > 0.5:
		custom_minimum_size.y = _height
	_rects.clear()
	if chapters.is_empty():
		return
	var full_width := 0.0
	for chapter in chapters:
		full_width += _text_width(String(chapter.label), FONT_SIZE, "sans_strong") + ICON + 22.0
	# 触摸档不退化到纯图标：真机没有 hover，图标模式下的章节名只存在于 tooltip，
	# 等于「看不见名字的页签」。手机上宁可挤一点也要留文字。
	icon_only = full_width > size.x and not TouchUI.is_touch()
	var x := 0.0
	var tab_width := (size.x / float(chapters.size())) if icon_only else 0.0
	for chapter in chapters:
		var width := tab_width if icon_only \
			else _text_width(String(chapter.label), FONT_SIZE, "sans_strong") + ICON + 22.0
		if not icon_only:
			width += (size.x - full_width) / float(chapters.size())
		_rects.append(Rect2(Vector2(x, 0.0), Vector2(width, _height)))
		x += width
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit((event as InputEventMouseMotion).position)
		if hit != _hover:
			_hover = hit
			if hit >= 0:
				var chapter: Dictionary = chapters[hit]
				var question := String(chapter.get("question", "")).strip_edges()
				tooltip_text = String(chapter.label) if question.is_empty() \
					else "%s\n%s" % [String(chapter.label), question]
			else:
				tooltip_text = ""
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hit >= 0 \
				else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		# 触摸档没有 hover 预热：必须按事件位置命中，否则手指点下去整排页签都不响应
		# （这是经济卷宗章节签「点不中」的实际原因，不只是尺寸小）。
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			var hit := _hit(button.position)
			if hit >= 0:
				_hover = hit
				var chapter_id := String(chapters[hit].id)
				if chapter_id != current:
					chapter_selected.emit(chapter_id)
				accept_event()


func _hit(point: Vector2) -> int:
	for i in range(_rects.size()):
		if (_rects[i] as Rect2).has_point(point):
			return i
	return -1


func _draw() -> void:
	var baseline_y := _height - 1.0
	draw_line(Vector2(0.0, baseline_y), Vector2(size.x, baseline_y), UITokens.DOSSIER_RULE_STRONG, 2.0)
	var indicator := _indicator_rect()
	if indicator.size.x > 0.0:
		var tab := Rect2(Vector2(indicator.position.x + 2.0, 3.0),
			Vector2(indicator.size.x - 4.0, _height - 4.0))
		draw_style_box(get_theme_stylebox("pressed", "PKChapterTab"), tab)
	for i in range(chapters.size()):
		if i >= _rects.size():
			break
		var chapter: Dictionary = chapters[i]
		var rect: Rect2 = _rects[i]
		var active := String(chapter.id) == current
		if i == _hover and not active:
			draw_style_box(get_theme_stylebox("hover", "PKChapterTab"),
				Rect2(rect.position + Vector2(2.0, 3.0), rect.size - Vector2(4.0, 4.0)))
		var ink := UITokens.DOSSIER_PAPER if active else UITokens.DOSSIER_INK_SOFT
		var icon_key := StringName(chapter.get("icon", &""))
		var label := String(chapter.label)
		if icon_only:
			_icon(icon_key, Rect2(rect.get_center() - Vector2(ICON, ICON) * 0.5 + Vector2(0.0, 1.0),
				Vector2(ICON, ICON)), ink)
			continue
		var content_width := ICON + 6.0 + _text_width(label, FONT_SIZE, "sans_strong")
		var x := rect.position.x + (rect.size.x - content_width) * 0.5
		_icon(icon_key, Rect2(Vector2(x, rect.get_center().y - ICON * 0.5 + 1.0),
			Vector2(ICON, ICON)), ink)
		_text(Vector2(x + ICON + 6.0, rect.get_center().y + 6.0), label, FONT_SIZE, ink, "sans_strong")
		if i < chapters.size() - 1 and not active and String(chapters[i + 1].id) != current:
			draw_line(Vector2(rect.end.x, 12.0), Vector2(rect.end.x, _height - 10.0),
				UITokens.DOSSIER_RULE, 1.0)
