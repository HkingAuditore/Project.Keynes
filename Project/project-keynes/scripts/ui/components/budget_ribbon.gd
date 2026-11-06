extends Control
class_name BudgetRibbon

## 财政预算卷宗顶部的固定纸带：一屏读完两个额度池。
##
## 左：国家购买每日总额（国库现金份额）；中：共同的 100% 分配带
## （科技 / 时代收购 / 开拓 / 未分配）；右：军事独立信封。
## 两侧刻意不做成同一根条：军事预算按国库现金另开信封，不与左侧相加，
## 这条纸带就是把这个容易误读的口径画出来，而不是写在脚注里。
##
## 撕边纸、铅笔抖线、剪纸标签沿用卷宗语汇；全部自绘，尺寸随容器宽度变化。

const RIBBON_HEIGHT := 74.0
const PAD_X := 12.0
const LEFT_WIDTH := 186.0
const LEFT_WIDTH_COMPACT := 146.0
const RIGHT_WIDTH := 176.0
const RIGHT_WIDTH_COMPACT := 128.0
const BAND_TOP := 46.0
const BAND_HEIGHT := 10.0
const TORN_DEPTH := 3.0
const COMPACT_WIDTH := 780.0

var _national_daily := 0
var _treasury_share_bp := 0
var _research_bp := 0
var _era_bp := 0
var _colonization_bp := 0
var _envelope_daily := 0
var _envelope_enabled := false
var _available := true


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0.0, RIBBON_HEIGHT)


func set_state(national_daily: int, treasury_share_bp: int, research_bp: int,
		era_bp: int, colonization_bp: int, envelope_daily: int,
		envelope_enabled: bool, available: bool) -> void:
	_national_daily = maxi(0, national_daily)
	_treasury_share_bp = clampi(treasury_share_bp, 0, 1000)
	_research_bp = clampi(research_bp, 0, 10000)
	_era_bp = clampi(era_bp, 0, 10000)
	_colonization_bp = clampi(colonization_bp, 0, 10000)
	_envelope_daily = maxi(0, envelope_daily)
	_envelope_enabled = envelope_enabled
	_available = available
	queue_redraw()


func _draw() -> void:
	if size.x < 40.0 or size.y < 20.0:
		return
	var compact := size.x < COMPACT_WIDTH
	var left_w := LEFT_WIDTH_COMPACT if compact else LEFT_WIDTH
	var right_w := RIGHT_WIDTH_COMPACT if compact else RIGHT_WIDTH
	_draw_paper()
	_draw_left_column(PAD_X, left_w)
	var band_x := PAD_X + left_w + 12.0
	var band_w := maxf(56.0, size.x - PAD_X - right_w - band_x - 10.0)
	_draw_band(band_x, band_w, compact)
	var right_x := maxf(band_x + band_w + 10.0, size.x - PAD_X - right_w)
	_draw_right_column(right_x, right_w, compact)


func _draw_paper() -> void:
	var paper := _torn_polygon()
	var shadow := PackedVector2Array()
	for point in paper:
		shadow.append(point + Vector2(1.2, 1.8))
	draw_colored_polygon(shadow, Color(UITokens.DOSSIER_INK, 0.10))
	draw_colored_polygon(paper, UITokens.DOSSIER_PAPER)
	var outline := PackedVector2Array(paper)
	outline.append(paper[0])
	draw_polyline(outline, Color(UITokens.DOSSIER_OXBLOOD, 0.20), 1.0, true)
	draw_rect(Rect2(0.0, 0.0, size.x, 2.0), Color(UITokens.DOSSIER_BRASS, 0.55))


func _torn_polygon() -> PackedVector2Array:
	var width := size.x
	var bottom := size.y - TORN_DEPTH
	var points := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(width, 0.0), Vector2(width, bottom)])
	var steps := maxi(8, int(width / 24.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x3B17 + steps
	for index in range(steps):
		var t := 1.0 - float(index + 1) / float(steps + 1)
		points.append(Vector2(width * t, bottom + TORN_DEPTH * rng.randf_range(0.3, 1.0)))
	points.append(Vector2(0.0, bottom + TORN_DEPTH * 0.55))
	return points


func _sketch_line(from_x: float, to_x: float, y: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var steps := maxi(4, int((to_x - from_x) / 28.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x71A3 + steps
	for index in range(steps + 1):
		var t := float(index) / float(steps)
		points.append(Vector2(lerpf(from_x, to_x, t), y + rng.randf_range(-0.6, 0.6)))
	return points


func _draw_left_column(x: float, width: float) -> void:
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	var numeral := UITokens.dossier_font("numeral")
	var muted := Color(UITokens.DOSSIER_INK_MUTED, 1.0)
	draw_string(strong, Vector2(x, 16.0), "国家购买 · 每日",
		HORIZONTAL_ALIGNMENT_LEFT, width, 12, muted)
	var amount := "暂不可用" if not _available else _amount(_national_daily)
	var colour := UITokens.DOSSIER_OXBLOOD if _available and _national_daily > 0 \
		else UITokens.DOSSIER_INK_MUTED
	draw_string(numeral, Vector2(x, 36.0), amount,
		HORIZONTAL_ALIGNMENT_LEFT, width, 19, Color(colour, 1.0))
	var share := "占国库 %.1f%%" % (float(_treasury_share_bp) / 100.0)
	draw_string(sans, Vector2(x, 56.0), share,
		HORIZONTAL_ALIGNMENT_LEFT, width, 12, muted)


func _draw_band(x: float, width: float, compact: bool) -> void:
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	draw_string(strong, Vector2(x, 16.0), "共同额度 · 100%",
		HORIZONTAL_ALIGNMENT_LEFT, width, 12,
		Color(UITokens.DOSSIER_INK_MUTED, 1.0))
	if not compact:
		_draw_legend(x, width)
	var segments := _segments()
	var cursor := x
	var free_bp := int(segments[3].bp)
	for segment in segments:
		var seg_width := width * float(segment.bp) / 10000.0
		if seg_width <= 0.0:
			continue
		var rect := Rect2(cursor, BAND_TOP, seg_width, BAND_HEIGHT)
		draw_rect(rect, Color(segment.tone, 0.88))
		# 未分配段压几道淡斜线，像没写完的账格。
		if String(segment.id) == "free":
			for line_x in range(int(cursor) + 4, int(cursor + seg_width), 9):
				draw_line(Vector2(float(line_x), BAND_TOP + BAND_HEIGHT),
					Vector2(float(line_x) + 5.0, BAND_TOP),
					Color(UITokens.DOSSIER_RULE, 0.55), 1.0)
		cursor += seg_width
	draw_rect(Rect2(x, BAND_TOP, width, BAND_HEIGHT),
		Color(UITokens.DOSSIER_RULE, 0.65), 1.0)
	# 图例已经写了四项百分比；带上不再叠一行小字，给纸边留呼吸。
	var free_hint := "余 %s" % _percent(free_bp)
	if compact and width > 80.0:
		var hint_width := sans.get_string_size(free_hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11).x
		draw_string(sans, Vector2(x + width - hint_width, 68.0), free_hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11,
			Color(UITokens.DOSSIER_INK_SOFT, 1.0))


func _draw_legend(x: float, width: float) -> void:
	var entries := [
		{"label": "科技 %s" % _percent(_research_bp),
			"tone": UITokens.DOSSIER_SLATE},
		{"label": "时代 %s" % _percent(_era_bp),
			"tone": UITokens.DOSSIER_UMBER},
		{"label": "开拓 %s" % _percent(_colonization_bp),
			"tone": UITokens.DOSSIER_VERDIGRIS},
		{"label": "余 %s" % _percent(_segments()[3].bp),
			"tone": UITokens.DOSSIER_PAPER_DEEP},
	]
	var cursor := x
	var font := UITokens.dossier_font("sans")
	for entry in entries:
		var tone: Color = entry.tone
		draw_rect(Rect2(cursor, 26.0, 7.0, 7.0), Color(tone, 0.95))
		draw_rect(Rect2(cursor, 26.0, 7.0, 7.0),
			Color(UITokens.DOSSIER_RULE, 0.7), 1.0)
		var label := String(entry.label)
		draw_string(font, Vector2(cursor + 10.0, 33.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11,
			Color(UITokens.DOSSIER_INK_MUTED, 1.0))
		cursor += 10.0 + font.get_string_size(label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11).x + 14.0
		if cursor > x + width - 40.0:
			return


func _draw_right_column(x: float, width: float, compact: bool) -> void:
	# 竖向虚线：军事是另一个池，视觉上也隔开。
	var line_x := x - 8.0
	var y := 8.0
	while y < size.y - TORN_DEPTH - 4.0:
		draw_line(Vector2(line_x, y), Vector2(line_x, minf(y + 4.0, size.y - TORN_DEPTH)),
			Color(UITokens.DOSSIER_RULE, 0.75), 1.0)
		y += 8.0
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	var numeral := UITokens.dossier_font("numeral")
	var muted := Color(UITokens.DOSSIER_INK_MUTED, 1.0)
	draw_string(strong, Vector2(x, 16.0), "军事 · 独立信封",
		HORIZONTAL_ALIGNMENT_LEFT, width, 12, muted)
	var amount := "未启用" if not _envelope_enabled else _amount(_envelope_daily)
	var colour := UITokens.DOSSIER_OXBLOOD if _envelope_enabled \
		else UITokens.DOSSIER_INK_MUTED
	draw_string(numeral, Vector2(x, 36.0), amount,
		HORIZONTAL_ALIGNMENT_LEFT, width, 18, Color(colour, 1.0))
	var note := "另计 · 不与左侧相加" if not compact else "另计"
	draw_string(sans, Vector2(x, 56.0), note,
		HORIZONTAL_ALIGNMENT_LEFT, width, 11, muted)


func _segments() -> Array:
	var total := 0
	var raw: Array = [
		{"id": "research", "bp": _research_bp, "tone": UITokens.DOSSIER_SLATE},
		{"id": "era", "bp": _era_bp, "tone": UITokens.DOSSIER_UMBER},
		{"id": "colonization", "bp": _colonization_bp,
			"tone": UITokens.DOSSIER_VERDIGRIS},
	]
	var segments: Array = []
	for entry in raw:
		var bp := clampi(int(entry.bp), 0, 10000 - total)
		segments.append({"id": entry.id, "bp": bp, "tone": entry.tone})
		total += bp
	segments.append({"id": "free", "bp": maxi(0, 10000 - total),
		"tone": UITokens.DOSSIER_PAPER_DEEP})
	return segments


static func _amount(cash: int) -> String:
	return UITokens.format_compact_number_cn(float(maxi(0, cash)) / 10000.0, 2)


static func _percent(bp: int) -> String:
	return "%.0f%%" % (float(clampi(bp, 0, 10000)) / 100.0)


## 剪纸分组标签：左侧压一道语义色条，右侧是燕尾缺口。
class GroupTag extends Control:
	const TAG_HEIGHT := 24.0
	const NOTCH := 9.0

	var _text := ""
	var _tone: Color = UITokens.DOSSIER_BRASS


	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0.0, TAG_HEIGHT)


	func configure(text: String, tone: Color) -> void:
		_text = text
		_tone = tone
		queue_redraw()


	func _draw() -> void:
		if size.x < 12.0:
			return
		var width := size.x
		var height := TAG_HEIGHT
		var tag := PackedVector2Array([
			Vector2(0.0, 0.0), Vector2(width - NOTCH, 0.0),
			Vector2(width, height * 0.5), Vector2(width - NOTCH, height),
			Vector2(0.0, height)])
		var shadow := PackedVector2Array()
		for point in tag:
			shadow.append(point + Vector2(1.0, 1.5))
		draw_colored_polygon(shadow, Color(UITokens.DOSSIER_INK, 0.10))
		draw_colored_polygon(tag, Color(_tone, 0.17))
		var outline := PackedVector2Array(tag)
		outline.append(tag[0])
		draw_polyline(outline, Color(_tone, 0.72), 1.0, true)
		draw_rect(Rect2(0.0, 0.0, 3.0, height), Color(_tone, 0.95))
		draw_string(UITokens.dossier_font("sans_strong"), Vector2(11.0, 16.0),
			_text, HORIZONTAL_ALIGNMENT_LEFT, maxf(20.0, width - NOTCH - 16.0), 13,
			Color(UITokens.DOSSIER_INK, 1.0))
