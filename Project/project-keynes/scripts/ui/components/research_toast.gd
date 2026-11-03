extends DossierChart
class_name ResearchToast

# Thin HUD toast for research completion and era promotion. Owned by
# GameUIManager; not a runtime. Notes are drawn, not instanced, and processing
# stops once the stack is empty.
# The stack lives in HUDLayer above the panel/archive scrim (GameUIManager raises
# its z_index), because a promotion is normally watched from inside the
# technology archive — the era badge itself sits under that scrim.

const DISPLAY_MSEC := 3200
const FADE_MSEC := 180
const MAX_VISIBLE := 2
const NOTE_WIDTH := 420.0
const NOTE_HEIGHT := 40.0
const NOTE_GAP := 8.0
const SLIDE_IN := 18.0
const SLIDE_OUT := 12.0
# Promotion notes are the one moment the HUD must survive an open archive: taller
# paper, era crest, gold rule, and a second line for the pending era reward.
const PROMOTE_WIDTH := 460.0
const PROMOTE_HEIGHT := 58.0
const PROMOTE_DISPLAY_MSEC := 4800
const PROMOTE_ICON := 30.0

var _entries: Array = []
var _note_style: StyleBoxTexture
var _era_textures := {}


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
		"kind": "research",
		"text": "「%s」研究完成 · 次日生效" % display_name,
		"start": now,
		"until": now + DISPLAY_MSEC,
	})
	visible = true
	set_process(true)
	queue_redraw()


## 时代晋升：与徽记特效、顶栏日历同一时刻，但即使在科技面板打开时也必须可见。
## reward_available 由 GameUIManager 传入未领取的时代奖励状态。
func show_era_promoted(era_id: String, era_name: String,
		reward_available: bool) -> void:
	var title := era_name.strip_edges()
	if title.is_empty():
		return
	var now := Time.get_ticks_msec()
	while _live_count(now) >= MAX_VISIBLE:
		_dismiss_oldest(now)
	_entries.append({
		"kind": "era",
		"era_id": era_id,
		"era_name": title,
		"text": "时代晋升 · %s" % title,
		"hint": "时代奖励待领取 · 点击顶部时代徽记" if reward_available else "",
		"start": now,
		"until": now + PROMOTE_DISPLAY_MSEC,
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
		_note_style = get_theme_stylebox("panel", "PKPaperToast").duplicate() as StyleBoxTexture
	var now := Time.get_ticks_msec()
	var y := 0.0
	for entry in _entries:
		var promoting := String(entry.get("kind", "")) == "era"
		var note_width := PROMOTE_WIDTH if promoting else NOTE_WIDTH
		var note_height := PROMOTE_HEIGHT if promoting else NOTE_HEIGHT
		var width := minf(note_width, size.x)
		var left := (size.x - width) * 0.5
		var age := float(now - int(entry.start))
		var remaining := float(int(entry.until) - now)
		var alpha := clampf(age / float(FADE_MSEC), 0.0, 1.0)
		var offset := (1.0 - _ease_out(alpha)) * SLIDE_IN
		if remaining < 0.0:
			var leaving := clampf(-remaining / float(FADE_MSEC), 0.0, 1.0)
			alpha = 1.0 - leaving
			offset = -leaving * SLIDE_OUT
		var rect := Rect2(left, y + offset, width, note_height)
		if promoting:
			_draw_promotion(rect, entry, alpha)
		else:
			_draw_note(rect, String(entry.text), alpha)
		y += note_height + NOTE_GAP


## 时代晋升纸贴：时代徽记 + 金线 + 标题，未领取时代奖励时补一行提示。
func _draw_promotion(rect: Rect2, entry: Dictionary, alpha: float) -> void:
	_note_style.modulate_color = _fade(Color.WHITE, alpha)
	draw_style_box(_note_style, rect)
	var gold := UITokens.ERA_BADGE_GOLD
	draw_rect(Rect2(rect.position + Vector2(8.0, 9.0), Vector2(3.0, rect.size.y - 18.0)),
		_fade(gold, alpha))
	var icon_rect := Rect2(rect.position + Vector2(16.0, 12.0),
		Vector2(PROMOTE_ICON, PROMOTE_ICON))
	var texture := _era_texture(String(entry.get("era_id", "")))
	if texture != null:
		draw_texture_rect(texture, icon_rect, false, _fade(Color.WHITE, alpha))
	var text_left := icon_rect.end.x + 12.0
	var text_width := rect.end.x - 16.0 - text_left
	var hint := String(entry.get("hint", ""))
	var title_baseline := rect.position.y + (34.0 if hint.is_empty() else 26.0)
	_text(Vector2(text_left, title_baseline),
		_fit_text(String(entry.text), 17, text_width, "sans_strong"),
		17, _fade(UITokens.DOSSIER_INK, alpha), "sans_strong")
	if not hint.is_empty():
		_text(Vector2(text_left, title_baseline + 20.0),
			_fit_text(hint, 13, text_width), 13,
			_fade(gold.darkened(0.28), alpha))


func _era_texture(era_id: String) -> Texture2D:
	if era_id.is_empty():
		return null
	if _era_textures.has(era_id):
		return _era_textures[era_id] as Texture2D
	var path := "res://assets/icons/era/era_%s.png" % era_id
	var texture := load(path) as Texture2D
	_era_textures[era_id] = texture
	return texture


func _draw_note(rect: Rect2, text: String, alpha: float) -> void:
	_note_style.modulate_color = _fade(Color.WHITE, alpha)
	draw_style_box(_note_style, rect)
	draw_rect(Rect2(rect.position + Vector2(8.0, 11.0), Vector2(3.0, 18.0)),
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
