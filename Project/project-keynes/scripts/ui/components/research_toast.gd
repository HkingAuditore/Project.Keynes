extends DossierChart
class_name ResearchToast

# Thin HUD toast for research completion. Owned by GameUIManager; not a runtime.
# Notes are drawn, not instanced, and processing stops once the stack is empty.

const DISPLAY_MSEC := 3200
const FADE_MSEC := 180
const MAX_VISIBLE := 2
const NOTE_WIDTH := 420.0
const NOTE_HEIGHT := 40.0
const NOTE_GAP := 8.0
const SLIDE_IN := 18.0
const SLIDE_OUT := 12.0

var _entries: Array = []
var _note_style: StyleBoxFlat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	visible = false


func show_research_completed(display_name: String) -> void:
	if display_name.strip_edges().is_empty():
		return
	var now := Time.get_ticks_msec()
	while _live_count(now) >= MAX_VISIBLE:
		_dismiss_oldest(now)
	_entries.append({
		"text": "「%s」研究完成 · 次日生效" % display_name,
		"start": now,
		"until": now + DISPLAY_MSEC,
	})
	visible = true
	set_process(true)
	queue_redraw()


func visible_texts() -> PackedStringArray:
	var out := PackedStringArray()
	var now := Time.get_ticks_msec()
	for entry in _entries:
		if now < int(entry.until):
			out.append(String(entry.text))
	return out


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var kept: Array = []
	for entry in _entries:
		if now < int(entry.until) + FADE_MSEC:
			kept.append(entry)
	_entries = kept
	if _entries.is_empty():
		visible = false
		set_process(false)
	queue_redraw()


func _live_count(now: int) -> int:
	var count := 0
	for entry in _entries:
		if now < int(entry.until):
			count += 1
	return count


func _dismiss_oldest(now: int) -> void:
	for entry in _entries:
		if now < int(entry.until):
			entry.until = now
			return


func _draw() -> void:
	if _entries.is_empty():
		return
	if _note_style == null:
		_note_style = StyleBoxFlat.new()
		_note_style.anti_aliasing = true
		_note_style.set_corner_radius_all(3)
		_note_style.set_border_width_all(1)
		_note_style.border_width_left = 4
		_note_style.shadow_size = 6
		_note_style.shadow_offset = Vector2(0.0, 2.0)
	var now := Time.get_ticks_msec()
	var width := minf(NOTE_WIDTH, size.x)
	var left := (size.x - width) * 0.5
	var y := 0.0
	for entry in _entries:
		var age := float(now - int(entry.start))
		var remaining := float(int(entry.until) - now)
		var alpha := clampf(age / float(FADE_MSEC), 0.0, 1.0)
		var offset := (1.0 - _ease_out(alpha)) * SLIDE_IN
		if remaining < 0.0:
			var leaving := clampf(-remaining / float(FADE_MSEC), 0.0, 1.0)
			alpha = 1.0 - leaving
			offset = -leaving * SLIDE_OUT
		var rect := Rect2(left, y + offset, width, NOTE_HEIGHT)
		_draw_note(rect, String(entry.text), alpha)
		y += NOTE_HEIGHT + NOTE_GAP


func _draw_note(rect: Rect2, text: String, alpha: float) -> void:
	_note_style.bg_color = _fade(UITokens.DOSSIER_PAPER, alpha)
	_note_style.border_color = _fade(UITokens.DOSSIER_RULE_STRONG, alpha)
	_note_style.shadow_color = Color(0.0, 0.0, 0.0, 0.22 * alpha)
	draw_style_box(_note_style, rect)
	draw_rect(Rect2(rect.position, Vector2(4.0, rect.size.y)),
		_fade(UITokens.DOSSIER_VERDIGRIS, alpha))
	var icon_rect := Rect2(rect.position + Vector2(14.0, 11.0), Vector2(18.0, 18.0))
	_icon(&"technology.state.completed", icon_rect, _fade(UITokens.DOSSIER_VERDIGRIS, alpha))
	var text_left := icon_rect.end.x + 10.0
	var text_width := rect.end.x - 14.0 - text_left
	_text(Vector2(text_left, rect.position.y + 26.0), _fit_text(text, 15, text_width,
		"sans_strong"), 15, _fade(UITokens.DOSSIER_INK, alpha), "sans_strong")


static func _fade(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, color.a * alpha)


static func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)
