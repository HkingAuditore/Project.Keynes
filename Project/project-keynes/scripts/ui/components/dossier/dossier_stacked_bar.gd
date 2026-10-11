extends DossierChart
class_name DossierStackedBar

## 一条带标题、合计与图例的堆叠条：用于收入构成、支出去向、在建流向。

const BAR_HEIGHT := 12.0
const LEGEND_ROW := 18.0

var title := ""
var total_text := ""
var _segments: Array = []
var _values := PackedFloat32Array()
var _from := PackedFloat32Array()
var _legend_rows := 1


func _init() -> void:
	super()
	custom_minimum_size = Vector2(200.0, 58.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_segments(p_title: String, segments: Array, p_total_text: String = "") -> void:
	title = p_title
	total_text = p_total_text
	_from = _current_values()
	_segments = segments
	_values = PackedFloat32Array()
	for segment in segments:
		_values.append(maxf(0.0, float((segment as Dictionary).get("value", 0.0))))
	_update_min_height()
	var tips := PackedStringArray([title])
	for segment in segments:
		tips.append("%s：%s" % [String(segment.get("label", "")), String(segment.get("text", ""))])
	tooltip_text = "\n".join(tips)
	_start_animation()


func _current_values() -> PackedFloat32Array:
	return _blend_arrays(_from, _values, _blend)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_min_height()


func _update_min_height() -> void:
	var rows := 1
	var x := 0.0
	var available := maxf(120.0, size.x)
	for segment in _segments:
		var item_width := _legend_item_width(segment)
		if x > 0.0 and x + item_width > available:
			rows += 1
			x = 0.0
		x += item_width
	if rows != _legend_rows or custom_minimum_size.y < 1.0:
		_legend_rows = rows
	var wanted := 20.0 + BAR_HEIGHT + 6.0 + LEGEND_ROW * float(_legend_rows)
	if absf(custom_minimum_size.y - wanted) > 0.5:
		custom_minimum_size.y = wanted


func _legend_item_width(segment: Dictionary) -> float:
	return 14.0 + _text_width("%s %s" % [String(segment.get("label", "")),
		String(segment.get("text", ""))], 11) + 14.0


func _draw() -> void:
	var w := size.x
	_text(Vector2(0.0, 13.0), title, 12, UITokens.DOSSIER_INK_SOFT, "sans_strong")
	if not total_text.is_empty():
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
		_text(Vector2(lx + 14.0 + label_width, ly + 13.0), String(segment.get("text", "")), 11,
			UITokens.DOSSIER_INK, "sans_strong")
		lx += item_width
