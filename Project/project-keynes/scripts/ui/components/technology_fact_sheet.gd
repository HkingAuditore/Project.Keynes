extends DossierChart
class_name TechnologyFactSheet

## 科技详情的事实表：左列键、右列值，长值自动换行，不再截断成「条件 · 制度 …」。

const KEY_WIDTH := 80.0
const LINE_GAP := 12.0
const FONT_SIZE := 18
const KEY_SIZE := 15

var _facts: Array = []
var _layout_width := -1.0
var _row_heights := PackedFloat32Array()


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## facts: [{key, value, accent?}]
func set_facts(facts: Array) -> void:
	if facts == _facts:
		return
	_facts = facts
	_relayout()


func facts() -> Array:
	return _facts


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and not is_equal_approx(_layout_width, size.x):
		_relayout()


func _relayout() -> void:
	_layout_width = size.x
	_row_heights.resize(_facts.size())
	var value_width := maxf(40.0, size.x - KEY_WIDTH)
	var font := _font("sans")
	var total := 0.0
	for index in range(_facts.size()):
		var value := String((_facts[index] as Dictionary).get("value", ""))
		var height := font.get_multiline_string_size(value, HORIZONTAL_ALIGNMENT_LEFT,
			value_width, FONT_SIZE).y
		_row_heights[index] = maxf(26.0, height)
		total += _row_heights[index] + LINE_GAP
	var target := maxf(0.0, total - LINE_GAP) + 4.0
	if not is_equal_approx(custom_minimum_size.y, target):
		custom_minimum_size = Vector2(0.0, target)
	queue_redraw()


func _draw() -> void:
	var font := _font("sans")
	var value_width := maxf(40.0, size.x - KEY_WIDTH)
	var y := 0.0
	for index in range(_facts.size()):
		var fact: Dictionary = _facts[index]
		var height := float(_row_heights[index]) if index < _row_heights.size() else 18.0
		_text(Vector2(0.0, y + 21.0), String(fact.get("key", "")), KEY_SIZE,
			UITokens.DOSSIER_INK_MUTED)
		var color: Color = fact.get("accent", UITokens.DOSSIER_INK)
		draw_multiline_string(font, Vector2(KEY_WIDTH, y + 21.0), String(fact.get("value", "")),
			HORIZONTAL_ALIGNMENT_LEFT, value_width, FONT_SIZE, -1, color)
		y += height + LINE_GAP
		if index < _facts.size() - 1:
			draw_line(Vector2(0.0, y - LINE_GAP * 0.5), Vector2(size.x, y - LINE_GAP * 0.5),
				Color(UITokens.DOSSIER_RULE, 0.5), 1.0)
