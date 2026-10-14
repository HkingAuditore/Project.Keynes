extends DossierChart
class_name InspectorNoteList

## 地块卷宗批注：左侧色签 + 自动换行的短句，用于警示与说明（承载告急、投资受阻……）。
## 数据形状沿用视图模型的 insights（id/text/accent）。

const FONT_SIZE := 13
const LINE_GAP := 6.0
const PAD_LEFT := 12.0

var _notes: Array = []
var _paragraphs: Array = []
var _layout_width := -1.0


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, 24.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_notes(notes: Array) -> void:
	var first := _notes.is_empty()
	_notes = notes.duplicate()
	_layout_width = -1.0
	_relayout()
	if first:
		_start_animation()
	queue_redraw()


func note_count() -> int:
	return _notes.size()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and absf(size.x - _layout_width) > 0.5:
		_relayout()


func _relayout() -> void:
	_paragraphs.clear()
	var width := maxf(40.0, (size.x if size.x > 1.0 else 380.0) - PAD_LEFT - 4.0)
	_layout_width = size.x
	var total := 0.0
	for raw in _notes:
		var note: Dictionary = raw
		var paragraph := TextParagraph.new()
		paragraph.width = width
		paragraph.add_string(String(note.get("text", "")), _font("sans"), FONT_SIZE)
		_paragraphs.append(paragraph)
		total += paragraph.get_size().y + LINE_GAP
	custom_minimum_size.y = maxf(1.0, total)
	queue_redraw()


static func tick_color(accent: Color) -> Color:
	if accent.is_equal_approx(UITokens.RISK) or accent.is_equal_approx(UITokens.DOSSIER_OXBLOOD):
		return UITokens.DOSSIER_OXBLOOD
	if accent.is_equal_approx(UITokens.WARN) or accent.is_equal_approx(UITokens.DOSSIER_BRASS):
		return UITokens.DOSSIER_BRASS
	if accent.is_equal_approx(UITokens.GOOD) or accent.is_equal_approx(UITokens.DOSSIER_VERDIGRIS):
		return UITokens.DOSSIER_VERDIGRIS
	return UITokens.DOSSIER_RULE_STRONG


func _draw() -> void:
	var y := 0.0
	var count := mini(_notes.size(), _paragraphs.size())
	for i in range(count):
		var note: Dictionary = _notes[i]
		var paragraph := _paragraphs[i] as TextParagraph
		var height := paragraph.get_size().y
		var appear := clampf(_grow * float(count + 1) - float(i), 0.0, 1.0) if _has_grown else 1.0
		var tick := tick_color(note.get("accent", UITokens.ACCENT))
		draw_rect(Rect2(Vector2(0.0, y + 2.0), Vector2(3.0, height - 4.0)), Color(tick, appear))
		var ink := UITokens.DOSSIER_OXBLOOD if tick == UITokens.DOSSIER_OXBLOOD \
			else UITokens.DOSSIER_INK_SOFT
		paragraph.draw(get_canvas_item(), Vector2(PAD_LEFT + (1.0 - appear) * 6.0, y),
			Color(ink, appear))
		y += height + LINE_GAP
