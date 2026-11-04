extends DossierChart
class_name DossierStackedBar

## 一条带标题、合计与图例的堆叠条：用于收入构成、支出去向、在建流向。

const BAR_HEIGHT := 12.0
const LEGEND_ROW := 18.0

var title := ""
var total_text := ""
## 合计与图例的数值是不是货币：是就在数字前画金币图标（见 MoneyDisplay）。
## 人口、在建座数这类非货币读数保持 false，否则会被当成金额。
var money_icon := false
## 图例（色块 + 名称 + 数值）默认跟随堆叠条。军事兵种名册本身已经逐条列出份额，
## 再复述一遍只是白占一行高度，所以那一处关掉图例、只保留条与合计。
var show_legend := true:
	set(value):
		if show_legend == value:
			return
		show_legend = value
		_update_min_height()
		queue_redraw()
var _segments: Array = []
var _values := PackedFloat32Array()
var _from := PackedFloat32Array()
var _legend_rows := 1
## 段点击回调：`func(segment_id: String, ratio: float)`，ratio 是该段内的相对位置
## （0..1）。收入构成这类只读图表留空即可；兵种编制条把点击换算成具体份额。
var segment_clicked := Callable()


func _init() -> void:
	super()
	custom_minimum_size = Vector2(200.0, 58.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_segments(p_title: String, segments: Array, p_total_text: String = "",
		p_money_icon: bool = false) -> void:
	title = p_title
	total_text = MoneyDisplay.strip_unit(p_total_text) if p_money_icon else p_total_text
	money_icon = p_money_icon
	_from = _current_values()
	_segments = segments
	_values = PackedFloat32Array()
	for segment in segments:
		_values.append(maxf(0.0, float((segment as Dictionary).get("value", 0.0))))
	_update_min_height()
	var tips := PackedStringArray([title])
	for segment in segments:
		tips.append("%s：%s" % [String(segment.get("label", "")),
			_segment_text(segment)])
	tooltip_text = "\n".join(tips)
	_start_animation()


## 图例里的数值文本：货币读数摘掉单位记号，单位由左侧图标负责。
func _segment_text(segment: Dictionary) -> String:
	var text := String(segment.get("text", ""))
	return MoneyDisplay.strip_unit(text) if money_icon else text


func _current_values() -> PackedFloat32Array:
	return _blend_arrays(_from, _values, _blend)


## 段数，供结构与截图测试断言。
func segment_count() -> int:
	return _segments.size()


## 堆叠条的实际可点区域（自绘控件，没有子节点可量）。
func _bar_rect() -> Rect2:
	return Rect2(Vector2(0.0, 20.0), Vector2(size.x, BAR_HEIGHT))


## 命中某段：返回 {id, ratio}，ratio 是落在该段内的相对位置（0..1）。
## 只对累计宽度 >0 的段判定，避免零宽度段抢走点击。
func segment_at(point: Vector2) -> Dictionary:
	if not _bar_rect().has_point(point) or not segment_clicked.is_valid():
		return {}
	var values := _current_values()
	var total := 0.0
	for value in values:
		total += value
	if total <= 0.0:
		return {}
	var bar := _bar_rect()
	var cursor := bar.position.x
	for index in range(mini(values.size(), _segments.size())):
		var width := bar.size.x * values[index] / total
		if width <= 0.5:
			continue
		if point.x >= cursor and point.x <= cursor + width:
			return {
				"id": String((_segments[index] as Dictionary).get("id", "")),
				"ratio": clampf((point.x - cursor) / width, 0.0, 1.0),
			}
		cursor += width
	return {}


func _gui_input(event: InputEvent) -> void:
	if not segment_clicked.is_valid():
		return
	if event is InputEventMouseMotion:
		var hit := segment_at((event as InputEventMouseMotion).position)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
			if not hit.is_empty() else Control.CURSOR_ARROW
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
			return
		var hit := segment_at(button.position)
		if hit.is_empty():
			return
		segment_clicked.call(String(hit.id), float(hit.ratio))
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_min_height()


func _update_min_height() -> void:
	var rows := 1
	var x := 0.0
	var available := maxf(120.0, size.x)
	if show_legend:
		for segment in _segments:
			var item_width := _legend_item_width(segment)
			if x > 0.0 and x + item_width > available:
				rows += 1
				x = 0.0
			x += item_width
	else:
		rows = 0
	if rows != _legend_rows or custom_minimum_size.y < 1.0:
		_legend_rows = rows
	var wanted := 20.0 + BAR_HEIGHT + 6.0 + LEGEND_ROW * float(_legend_rows)
	if absf(custom_minimum_size.y - wanted) > 0.5:
		custom_minimum_size.y = wanted


func _legend_item_width(segment: Dictionary) -> float:
	return 14.0 + _legend_text_width(segment) + 14.0


## 图例一项（色块 + 名称 + 数值）的宽度，货币读数要把金币的占位算进去。
func _legend_text_width(segment: Dictionary) -> float:
	var body := "%s %s" % [String(segment.get("label", "")), _segment_text(segment)]
	if money_icon:
		return MoneyDisplay.slot_width(11) + _text_width(body, 11)
	return _text_width(body, 11)


func _draw() -> void:
	var w := size.x
	_text(Vector2(0.0, 13.0), title, 12, UITokens.DOSSIER_INK_SOFT, "sans_strong")
	if not total_text.is_empty():
		if money_icon:
			_money_text_right(w, 13.0, total_text, 12, UITokens.DOSSIER_INK, "sans_strong")
		else:
			_text(Vector2(0.0, 13.0), total_text, 12, UITokens.DOSSIER_INK, "sans_strong",
				HORIZONTAL_ALIGNMENT_RIGHT, w)
	var bar := Rect2(Vector2(0.0, 20.0), Vector2(w, BAR_HEIGHT))
	_rounded_bar(bar, UITokens.DOSSIER_TRACK, 3.0)
	var values := _current_values()
	var total := 0.0
	for v in values:
		total += v
	if total > 0.0:
		var x := 0.0
		var full := w * _grow
		for i in range(values.size()):
			var width := full * values[i] / total
			if width >= 0.5:
				var color: Color = _segments[i].get("color", UITokens.DOSSIER_BRASS)
				draw_rect(Rect2(Vector2(x, bar.position.y), Vector2(width, BAR_HEIGHT)), color)
				if x > 0.0:
					draw_line(Vector2(x, bar.position.y), Vector2(x, bar.end.y),
						UITokens.DOSSIER_PAPER, 1.0)
			x += width
	draw_rect(bar, UITokens.DOSSIER_RULE, false, 1.0)
	var lx := 0.0
	var ly := bar.end.y + 6.0
	if not show_legend:
		return
	for segment in _segments:
		var item_width := _legend_item_width(segment)
		if lx > 0.0 and lx + item_width > w:
			lx = 0.0
			ly += LEGEND_ROW
		var color: Color = segment.get("color", UITokens.DOSSIER_BRASS)
		draw_rect(Rect2(Vector2(lx, ly + 4.0), Vector2(9.0, 9.0)), color)
		_text(Vector2(lx + 14.0, ly + 13.0), String(segment.get("label", "")), 11,
			UITokens.DOSSIER_INK_MUTED)
		var label_width := _text_width(String(segment.get("label", "")) + " ", 11)
		var value_x := lx + 14.0 + label_width
		if money_icon:
			_money_text(Vector2(value_x, ly + 13.0), _segment_text(segment), 11,
				UITokens.DOSSIER_INK, "sans_strong")
		else:
			_text(Vector2(value_x, ly + 13.0), String(segment.get("text", "")), 11,
				UITokens.DOSSIER_INK, "sans_strong")
		lx += item_width
