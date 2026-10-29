extends MarginContainer
class_name AnnualSection

## 长卷中的一章。
##
## 模板固定：巨型章节序号（溢入左页边）→ 眉题 → 48px 标题 → 导语 →
## 正文 → 关键数字带 → 图表 → 细线账簿 → 尾注。
## 章与章之间靠 200px 空白分隔，没有任何分节框或色块。
##
## 图表在章节首次进入视口时才绑定数据（`play_in`），避免离屏整形文本与绘制。

var index := 0
var _chapter: Dictionary = {}
var _model: Dictionary = {}
var _header: Control
var _figures: AnnualMetricBand
var _column: VBoxContainer
var _binds: Array[Callable] = []
var _charts: Array[Control] = []
var _margin := 259.0
var _measure := 660.0
var _chart_width := 1080.0
var _narrow := false
var _viewport := Vector2(1920.0, 1080.0)
var _revealed := false

const CHAPTER_EMBLEMS := preload("res://assets/ui/annual_chronicle/chronicle_chapter_emblems.png")
const AnnualGradeRulerScript = preload("res://scripts/ui/components/annual_report/charts/annual_grade_ruler.gd")
func build(p_index: int, chapter: Dictionary, model: Dictionary, layout: Dictionary) -> void:
	index = p_index
	_chapter = chapter
	_model = model
	_margin = float(layout.get("pad", layout.get("margin", 72.0)))
	_measure = float(layout.get("measure", 660.0))
	_chart_width = float(layout.get("chart", _measure))
	_narrow = bool(layout.get("narrow", false))
	_viewport = layout.get("viewport", Vector2(1920.0, 1080.0))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("margin_left", int(_margin))
	add_theme_constant_override("margin_right", int(_margin))
	add_theme_constant_override("margin_top", 0)
	add_theme_constant_override("margin_bottom", 0)

	_column = VBoxContainer.new()
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_theme_constant_override("separation", 0)
	add_child(_column)

	_build_header()
	_spacer(16.0)
	_build_figures()
	_build_visuals()
	_build_ledger()
	_build_tail()


func charts() -> Array[Control]:
	return _charts


func play_in(instant: bool = false) -> void:
	if _revealed:
		return
	_revealed = true
	for bind in _binds:
		bind.call()
	_binds.clear()
	if instant or UIAnimation.reduced_motion():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 1.0, AnnualReportTokens.SECTION_PLAY_IN)


# ── 章首 ────────────────────────────────────────────────────────────────────

func _build_header() -> void:
	# 章首也采用剪纸：章号是一块淡彩纸片，标题用重手绘字形压在纸面上。
	var display: Font = UITokens.annual_font("display")
	var soft: Font = UITokens.annual_font("display_soft")
	var title_size: int = 40 if _narrow else UITokens.CHRONICLE_H1
	var lead_size: int = 17 if _narrow else UITokens.CHRONICLE_LEAD
	var title_width: float = _measure
	var emblem_size: float = clampf(_measure * 0.17, 64.0, 118.0)
	title_width = maxf(190.0, _measure - emblem_size - 12.0)
	var kicker_height: float = 18.0
	var title_top: float = kicker_height + 6.0
	var title_height: float = display.get_height(title_size) * 1.14
	# 章首那行现在只交代「这是什么数据」，恒为一行。高度按字体实测行数给，
	# 不再恒留三行——恒留会在每章开头压出近百像素的纯白空洞。空串则整块不建。
	var lead_text: String = String(_chapter.get("lead", ""))
	var lead_top: float = title_top + title_height + 12.0
	var lead_height: float = 0.0
	if not lead_text.is_empty():
		var measured: float = soft.get_multiline_string_size(lead_text, HORIZONTAL_ALIGNMENT_LEFT, _measure, lead_size).y
		lead_height = minf(measured, float(lead_size) * 1.52 * 2.0) + 4.0
	var height: float = (lead_top + lead_height + 4.0) if lead_height > 0.0 else (title_top + title_height + 4.0)
	height = maxf(height, title_top + title_height + 8.0)
	# 水印字号由内容高度反推：数字底边压在导语基线上，不再向下压正文。
	var number_size: int = clampi(int(height * 1.05), 56,
		mini(AnnualReportTokens.chapter_number_size(_viewport), int(_measure * 0.30)))
	var baseline: float = height - 6.0

	_header = Control.new()
	_header.custom_minimum_size = Vector2(0.0, height)
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mark := _ChapterMark.new()
	mark.index = int(_chapter.get("number", index + 1))
	mark.tone = Color(UITokens.CHRONICLE_PENCIL_BLUE.r, UITokens.CHRONICLE_PENCIL_BLUE.g,
		UITokens.CHRONICLE_PENCIL_BLUE.b, 0.20)
	mark.size_px = number_size
	mark.right = _measure
	mark.baseline = baseline
	mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_header.add_child(mark)

	var kicker := _text_label("第 %02d 章" % int(_chapter.get("number", index + 1)), 13, UITokens.CHRONICLE_RED, true)
	kicker.add_theme_color_override("font_color", UITokens.CHRONICLE_PENCIL_RED)
	_place(kicker, Vector2(0.0, 0.0), Vector2(title_width, kicker_height))
	_header.add_child(kicker)

	var title := _text_label(String(_chapter.get("title", "")), title_size, UITokens.CHRONICLE_INK, false)
	_place(title, Vector2(0.0, title_top), Vector2(title_width, title_height + 4.0))
	_header.add_child(title)

	var emblem_index: int = clampi(index, 0, 8)
	var emblem_art := _ChapterEmblem.new()
	emblem_art.name = "ChapterEmblem"
	emblem_art.atlas = CHAPTER_EMBLEMS
	emblem_art.index = emblem_index
	var emblem_top: float = -24.0
	_place(emblem_art, Vector2(_measure - emblem_size * 0.94, emblem_top),
		Vector2(emblem_size, emblem_size))
	_header.add_child(emblem_art)

	if lead_height > 0.0:
		var lead := _text_label(lead_text, lead_size, UITokens.CHRONICLE_MUTED, false)
		lead.add_theme_font_override("font", soft)
		lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lead.max_lines_visible = 2
		lead.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_place(lead, Vector2(0.0, lead_top), Vector2(_measure, lead_height))
		_header.add_child(lead)
	_column.add_child(_header)
	var pencil_rule := ColorRect.new()
	_pencil_rule(pencil_rule)
	_column.add_child(pencil_rule)


func _spacer(height: float) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, height)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(gap)


func _pencil_rule(rule: ColorRect) -> void:
	rule.color = Color(UITokens.CHRONICLE_INK.r,
		UITokens.CHRONICLE_INK.g, UITokens.CHRONICLE_INK.b, 0.58)
	rule.custom_minimum_size = Vector2(0.0, 2.0)
	rule.size_flags_horizontal = Control.SIZE_FILL
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ── 正文 ────────────────────────────────────────────────────────────────────
# 这一层已经没有多段正文了：每章唯一的说明文字是章首那行 lead。段落通道拆掉，
# 是为了让「再来一段解释」没有地方可塞——它过去正是口径说明涌入的入口。

# ── 关键数字带 ──────────────────────────────────────────────────────────────
# ── 关键数字带 ──────────────────────────────────────────────────────────────

func _build_figures() -> void:
	var figures: Array = _chapter.get("figures", [])
	if figures.is_empty():
		return
	_figures = AnnualMetricBand.new()
	_figures.set_compact(_narrow or int(_chart_width) < 720, _chart_width)
	_figures.set_figures(figures)
	_figures.custom_minimum_size.x = _chart_width
	_figures.size_flags_horizontal = Control.SIZE_FILL
	_column.add_child(_figures)
	_spacer(20.0)


# ── 图表 ────────────────────────────────────────────────────────────────────

func _build_visuals() -> void:
	for visual in _chapter.get("visuals", []):
		match String(visual.get("kind", "")):
			"month_area":
				_add_chart("各月已结算增加值", _month_chart(visual))
			"radar":
				_add_chart("八维满意度（人口加权）", _radar_chart(visual))
			"bars":
				_add_chart(String(visual.get("label", "分项")), _bars_chart(visual))
			"stairs":
				_add_chart("聚落等级分布", _stairs_chart(visual))
			"era":
				_add_chart("文明阶段", _era_chart(visual))
			"tax":
				_add_chart("税种构成", _tax_chart(visual))
			"score_parts":
				_add_chart("十项评分分解", _score_chart(visual))
			"grade_ruler":
				_add_chart("评级位置", _ruler_chart(visual))
	var notes: Array = _chapter.get("margin_notes", [])
	for note in notes:
		var label := _text_label("— " + String(note), 13, UITokens.CHRONICLE_MUTED, true)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(_measure, 0.0)
		label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_column.add_child(label)
	if not notes.is_empty():
		_spacer(AnnualReportTokens.GAP_BLOCK * 0.5)


func _add_chart(title: String, node: Control) -> void:
	if node == null:
		return
	var caption := _text_label(title, 14, UITokens.CHRONICLE_MUTED, true)
	caption.custom_minimum_size = Vector2(_chart_width, 0.0)
	_column.add_child(caption)
	_spacer(9.0)
	node.custom_minimum_size.x = _chart_width
	node.size_flags_horizontal = Control.SIZE_FILL
	_column.add_child(node)
	_charts.append(node)
	_spacer(AnnualReportTokens.GAP_BLOCK)


func _month_chart(visual: Dictionary) -> Control:
	var gdp: PackedFloat64Array = visual.get("gdp", PackedFloat64Array())
	var population: PackedFloat64Array = visual.get("population", PackedFloat64Array())
	var observed: int = gdp.size()
	if observed < 1:
		return null
	var area := AnnualMonthChart.new()
	area.set_reveal_enabled(not UIAnimation.reduced_motion())
	area.custom_minimum_size = Vector2(_chart_width, 210.0)
	if _narrow:
		area.custom_minimum_size.y = 160.0
	_binds.append(func() -> void:
		if not area.set_data(gdp, observed):
			area.visible = false)
	if population.size() == observed:
		var strip := AnnualMonthChart.new()
		strip.set_reveal_enabled(not UIAnimation.reduced_motion())
		strip.set_compact(true)
		strip.custom_minimum_size = Vector2(_chart_width, 76.0)
		_binds.append(func() -> void:
			if not strip.set_data(population, observed):
				strip.visible = false)
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(area)
		var caption := _text_label("各月末人口", 13, UITokens.CHRONICLE_MUTED, true)
		row.add_child(caption)
		row.add_child(strip)
		return row
	return area


func _radar_chart(visual: Dictionary) -> Control:
	var names: PackedStringArray = visual.get("names", PackedStringArray())
	var values: PackedFloat64Array = visual.get("values", PackedFloat64Array())
	if values.size() < 3:
		return null
	var radar := AnnualRadarDims.new()
	radar.set_reveal_enabled(not UIAnimation.reduced_motion())
	var width: float = minf(_chart_width, 520.0 if _narrow else 620.0)
	radar.custom_minimum_size = Vector2(width, width * 0.82)
	var previous: PackedFloat64Array = visual.get("previous", PackedFloat64Array())
	_binds.append(func() -> void:
		if not radar.set_data(names, values, previous):
			radar.visible = false)
	return radar


func _bars_chart(visual: Dictionary) -> Control:
	var rows: Array = visual.get("rows", [])
	if rows.is_empty():
		return null
	var bars := AnnualIndustryBars.new()
	bars.set_reveal_enabled(not UIAnimation.reduced_motion())
	bars.custom_minimum_size = Vector2(_chart_width, 200.0)
	_binds.append(func() -> void:
		if not bars.set_data(rows, 8):
			bars.visible = false)
	return bars


func _stairs_chart(visual: Dictionary) -> Control:
	var values: PackedFloat64Array = visual.get("values", PackedFloat64Array())
	if values.size() < 2:
		return null
	var stairs := AnnualTierStairs.new()
	stairs.set_reveal_enabled(not UIAnimation.reduced_motion())
	stairs.custom_minimum_size = Vector2(_chart_width, 230.0)
	var names: PackedStringArray = visual.get("names", PackedStringArray())
	var previous: PackedFloat64Array = visual.get("previous", PackedFloat64Array())
	_binds.append(func() -> void:
		if not stairs.set_data(values, previous, names):
			stairs.visible = false)
	return stairs


func _era_chart(visual: Dictionary) -> Control:
	var names: PackedStringArray = visual.get("names", PackedStringArray())
	if names.is_empty():
		return null
	var line := AnnualEraLine.new()
	line.set_reveal_enabled(not UIAnimation.reduced_motion())
	line.custom_minimum_size = Vector2(minf(_chart_width, 900.0),
		102.0 if _narrow else 112.0)
	var era_index: int = int(visual.get("index", 0))
	_binds.append(func() -> void:
		if not line.set_data(era_index, names):
			line.visible = false)
	return line


func _tax_chart(visual: Dictionary) -> Control:
	var parts: Array = visual.get("parts", [])
	if parts.is_empty():
		return null
	var stack := AnnualTaxStack.new()
	stack.set_reveal_enabled(not UIAnimation.reduced_motion())
	stack.custom_minimum_size = Vector2(_chart_width, 108.0)
	_binds.append(func() -> void:
		if not stack.set_data(parts):
			stack.visible = false)
	return stack


func _score_chart(visual: Dictionary) -> Control:
	var parts: PackedInt64Array = visual.get("parts", PackedInt64Array())
	if parts.is_empty():
		return null
	var chart := AnnualScoreParts.new()
	chart.set_reveal_enabled(not UIAnimation.reduced_motion())
	chart.custom_minimum_size = Vector2(_chart_width, 30.0 * float(parts.size()) + 54.0)
	var labels: PackedStringArray = visual.get("labels", PackedStringArray())
	var weights: PackedFloat32Array = visual.get("weights", PackedFloat32Array())
	_binds.append(func() -> void:
		if not chart.set_data(parts, labels, weights):
			chart.visible = false)
	return chart


func _ruler_chart(visual: Dictionary) -> Control:
	var ruler: AnnualGradeRuler = AnnualGradeRulerScript.new()
	ruler.set_reveal_enabled(not UIAnimation.reduced_motion())
	ruler.custom_minimum_size = Vector2(minf(_chart_width, 520.0), 56.0)
	var score: float = float(visual.get("score", 0.0))
	var cap: int = int(visual.get("cap", -1))
	var complete: bool = bool(visual.get("complete", true))
	_binds.append(func() -> void:
		ruler.set_data(score, String(visual.get("grade", "—")), cap, complete, visual.get("bands", [])))
	return ruler


# ── 账簿 ────────────────────────────────────────────────────────────────────

func _build_ledger() -> void:
	var rows: Array = _chapter.get("rows", [])
	if rows.is_empty():
		return
	var ledger := AnnualLedger.new()
	ledger.custom_minimum_size = Vector2(_chart_width, AnnualLedger.HEADER_HEIGHT + AnnualLedger.ROW_HEIGHT * float(rows.size()))
	ledger.size_flags_horizontal = Control.SIZE_FILL
	ledger.set_rows(rows, bool(_chapter.get("has_previous", false)))
	_column.add_child(ledger)
	_spacer(AnnualReportTokens.GAP_BLOCK)


# ── 尾注 ────────────────────────────────────────────────────────────────────

func _build_tail() -> void:
	var details: Array = _chapter.get("details", [])
	if details.is_empty():
		return
	for detail in details:
		var label := RichTextLabel.new()
		label.bbcode_enabled = false
		label.fit_content = true
		label.scroll_active = false
		label.selection_enabled = true
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.custom_minimum_size = Vector2(_measure, 0.0)
		label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		label.text = String(detail)
		label.add_theme_font_override("normal_font", UITokens.annual_font("body_soft"))
		label.add_theme_font_size_override("normal_font_size", 15)
		label.add_theme_color_override("default_color", Color(UITokens.CHRONICLE_MUTED.r, UITokens.CHRONICLE_MUTED.g, UITokens.CHRONICLE_MUTED.b, 1.0))
		label.add_theme_constant_override("line_separation", 5)
		_column.add_child(label)
		_spacer(6.0)
	var tail := ColorRect.new()
	tail.color = Color(UITokens.CHRONICLE_INK.r, UITokens.CHRONICLE_INK.g, UITokens.CHRONICLE_INK.b, 0.28)
	tail.custom_minimum_size = Vector2(48.0, 1.0)
	tail.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(tail)


# ── 工具 ────────────────────────────────────────────────────────────────────

func _text_label(text: String, size_px: int, color: Color, tracked: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", UITokens.annual_font("label" if tracked else "display"))
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	return label


func _place(control: Control, at: Vector2, extent: Vector2) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = at
	control.size = extent


## 章节序号：右缘对齐版心右缘，退成一层极淡的墨，和眉题共用一条基线。
## 纸只有这么宽，所以它不再溢到页边外 —— 而是"印在纸上的大号页码"。
class _ChapterMark extends Control:
	var index := 1
	var tone := Color(0.19, 0.15, 0.12, 0.14)
	var size_px := 168
	var right := 660.0
	var baseline := 200.0

	func _draw() -> void:
		var font := UITokens.annual_font("display")
		var text := "%02d" % index
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x
		var x: float = clampf(right - width, 0.0, maxf(0.0, size.x - width))
		draw_string(font, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, tone)


## The generated object already contains its ivory cut-paper silhouette and
## contact shadow; a second backing here would read as a pale card.
class _ChapterEmblem extends Control:
	var atlas: Texture2D
	var index := 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		queue_redraw()

	func _draw() -> void:
		if atlas == null:
			return
		var source := Rect2(
			(float(index % 3) * 512.0),
			(float(index / 3) * 512.0),
			512.0,
			512.0,
		)
		draw_texture_rect_region(atlas, Rect2(Vector2.ZERO, size), source)
