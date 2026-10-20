extends Control
class_name AnnualCoverView

## 封面 = 长纸的第一页。
##
## 它不是"整屏版式"，而是一列纸（宽 ≈ 视口 44%，居中，上下出血）的第一屏：
## 顶端一段版画（插画在纸内、下沿化进纸里），下面是眉题、巨型标题、国名、
## 印章与得分、评级标尺、三个关键数字，最后一行提示继续下滑。
##
## 三条构图原则：
##   1. 全部落在纸的版心里，没有一条通栏横带 —— 旧版四个 KPI 铺满整屏，
##      正是"像 PPT"的根源。
##   2. 只有一个焦点：标题块。其余靠字号与空白的落差排队。
##   3. 分隔只用空白与发丝线，不出现任何卡片、边框、色块底。

const InkBleedShader = preload("res://shaders/ui/annual_ink_bleed.gdshader")
const CoverWashShader = preload("res://shaders/ui/annual_cover_wash.gdshader")
const SealPressShader = preload("res://shaders/ui/annual_seal_press.gdshader")
const SealTexture = preload("res://assets/ui/annual_chronicle/annual_seal.png")
const RewardMoteScene = preload("res://scenes/ui/annual_report/reward_mote.tscn")

signal begin_requested()

var _art_clip: Control
var _art: TextureRect
var _wash: ColorRect
var _kicker: Label
var _title: Label
var _rule: ColorRect
var _country: Label
var _seal: Control
var _seal_art: TextureRect
var _grade: Label
var _score: Label
var _score_unit: Label
var _reward: Label
var _ruler: AnnualGradeRuler
var _numerals: Array[Label] = []
var _captions: Array[Label] = []
var _deltas: Array[Label] = []
var _cue: Label

var _model: Dictionary = {}
var _art_material: ShaderMaterial
var _title_material: ShaderMaterial
var _seal_material: ShaderMaterial
var _wash_material: ShaderMaterial
var _opening: Tween
var _page_height := 0.0
var _page_cap := 0.0


func _ready() -> void:
	if _art != null:
		return
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_build()
	resized.connect(_relayout)


# ── 构建 ────────────────────────────────────────────────────────────────────

func _build() -> void:
	# 版画必须被纸缘裁掉，否则会画到桌面上。
	# 注意用 Control.clip_contents 而不是 CanvasItem.clip_children —— 后者只对
	# 自绘节点（贴图/多边形）生效，Control 自己不绘制时裁剪矩形是空的。
	_art_clip = Control.new()
	_art_clip.clip_contents = true
	_art_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_art_clip)
	_art = TextureRect.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_SCALE
	_art_clip.add_child(_art)
	_art_material = ShaderMaterial.new()
	_art_material.shader = InkBleedShader
	_art_material.set_shader_parameter("bleed", 1.2)
	_art_material.set_shader_parameter("edge", 0.06)
	_art_material.set_shader_parameter("direction", Vector2(0.15, 1.0))
	_art_material.set_shader_parameter("rim", 0.12)
	_art_material.set_shader_parameter("noise_scale", 5.0)
	_art_material.set_shader_parameter("noise_amount", 0.13)
	# 材质常驻：它不光做开场落墨，版画下沿"化进纸里"的羽化也在这里。
	# 只在开场时才挂上去的话，关掉动效或开场结束就会露出一条硬直的下沿。
	_art.material = _art_material

	_wash = ColorRect.new()
	_wash.color = Color(1, 1, 1, 1)
	_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wash_material = ShaderMaterial.new()
	_wash_material.shader = CoverWashShader
	_wash_material.set_shader_parameter("paper_color", UITokens.CHRONICLE_SHEET_LIGHT)
	_wash_material.set_shader_parameter("axis", 1)
	_wash_material.set_shader_parameter("strength", 0.98)
	_wash_material.set_shader_parameter("feather", 0.42)
	_wash_material.set_shader_parameter("edge_taper", 0.10)
	_wash.material = _wash_material
	add_child(_wash)

	_kicker = _label("", 13, UITokens.CHRONICLE_BRASS, "label")
	add_child(_kicker)

	_title = _label("国家年度\n发展报告", UITokens.CHRONICLE_DISPLAY_COVER, UITokens.CHRONICLE_INK, "display")
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_title.add_theme_color_override("font_outline_color", Color(UITokens.CHRONICLE_SHEET_LIGHT.r, UITokens.CHRONICLE_SHEET_LIGHT.g, UITokens.CHRONICLE_SHEET_LIGHT.b, 0.45))
	add_child(_title)
	_title_material = ShaderMaterial.new()
	_title_material.shader = InkBleedShader
	_title_material.set_shader_parameter("bleed", 1.2)
	_title_material.set_shader_parameter("edge", 0.035)
	_title_material.set_shader_parameter("direction", Vector2(1.0, 0.0))
	_title_material.set_shader_parameter("rim", 0.0)
	_title_material.set_shader_parameter("noise_scale", 7.0)
	_title_material.set_shader_parameter("noise_amount", 0.1)
	_title.material = _title_material

	_rule = ColorRect.new()
	_rule.color = Color(UITokens.CHRONICLE_INK.r, UITokens.CHRONICLE_INK.g, UITokens.CHRONICLE_INK.b, 0.5)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rule)

	_country = _label("", 28, UITokens.CHRONICLE_INK, "display_soft")
	_country.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_country.max_lines_visible = 2
	_country.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_country)

	_seal = Control.new()
	_seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_seal)
	_seal_art = TextureRect.new()
	_seal_art.texture = SealTexture
	_seal_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_seal_art.stretch_mode = TextureRect.STRETCH_SCALE
	_seal_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seal_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seal.add_child(_seal_art)
	_seal_material = ShaderMaterial.new()
	_seal_material.shader = SealPressShader
	_seal_material.set_shader_parameter("press", 1.0)
	_seal_material.set_shader_parameter("ring", 0.0)
	_seal_material.set_shader_parameter("glint", -1.0)
	_seal_material.set_shader_parameter("ink", UITokens.CHRONICLE_RED)
	_seal_art.material = _seal_material
	_grade = _label("—", 72, UITokens.CHRONICLE_RED, "display")
	_grade.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_grade.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_grade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seal.add_child(_grade)

	_score = _label("", 48, UITokens.CHRONICLE_INK, "numeral")
	add_child(_score)
	_score_unit = _label("综合得分 / 100", 13, UITokens.CHRONICLE_MUTED, "label")
	add_child(_score_unit)
	_reward = _label("", 15, UITokens.CHRONICLE_RED, "display_soft")
	add_child(_reward)

	_ruler = AnnualGradeRuler.new()
	_ruler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ruler)

	for i in 3:
		var numeral := _label("", UITokens.CHRONICLE_NUMERAL_XL, UITokens.CHRONICLE_INK, "numeral")
		add_child(numeral)
		_numerals.append(numeral)
		var caption := _label("", 13, UITokens.CHRONICLE_MUTED, "label")
		add_child(caption)
		_captions.append(caption)
		var delta := _label("", 13, UITokens.CHRONICLE_BRASS, "label")
		add_child(delta)
		_deltas.append(delta)

	_cue = _label("↓  向下卷动，展开正文", 13, UITokens.CHRONICLE_MUTED, "label")
	_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cue)

	_apply_model()
	_relayout()


func _label(text: String, size_px: int, color: Color, kind: String) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", UITokens.annual_font(kind))
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	return label


# ── 数据 ────────────────────────────────────────────────────────────────────

func present(model: Dictionary) -> void:
	if _art == null:
		_ready()
	_model = model
	_apply_model()
	_relayout()


## 封面这一屏的可用高度。纸的上沿之上要留一段桌面（"这张纸从哪里开始"的
## 唯一证据），封面必须让开它 —— 否则最后一行提示会被顶到屏幕外。
## 0 或负数表示按整屏算。
func set_page_cap(value: float) -> void:
	_page_cap = maxf(0.0, value)
	_relayout()


func _apply_model() -> void:
	if _title == null:
		return
	var available: bool = not _model.is_empty() and bool(_model.get("available", false))
	var complete: bool = bool(_model.get("complete", false))
	_kicker.text = "第 %d 年  ·  国家档案" % int(_model.get("year", 1))
	_country.text = String(_model.get("country_name", "本国"))
	_country.tooltip_text = _country.text
	_grade.text = String(_model.get("grade", "—"))
	_score.text = "%.2f" % float(_model.get("score", 0.0))
	_score_unit.text = "综合得分 / 100"
	_score_unit.visible = complete
	_reward.text = "理念嘉奖  +%s 点" % String(_model.get("reward_text", "0"))
	_reward.visible = complete and available
	if not complete:
		_score.text = "—"
	_art.texture = _cover_texture()
	var items: Array = _model.get("kpis", [])
	for i in _numerals.size():
		var has_item: bool = i < items.size()
		var item: Dictionary = items[i] if has_item else {}
		_numerals[i].text = String(item.get("current", "—")) if has_item else ""
		_captions[i].text = String(item.get("label", "")) if has_item else ""
		var delta: String = String(item.get("delta", "—")) if has_item else "—"
		var direction: int = int(item.get("direction", 0)) if has_item else 0
		_deltas[i].text = delta if delta != "—" and not delta.is_empty() else ""
		_deltas[i].add_theme_color_override("font_color",
			UITokens.CHRONICLE_BRASS if direction > 0
			else (UITokens.CHRONICLE_RED if direction < 0 else UITokens.CHRONICLE_MUTED))
		_deltas[i].visible = available and not _deltas[i].text.is_empty()
	_ruler.set_data(float(_model.get("score", 0.0)), String(_model.get("grade", "—")),
		int(_model.get("grade_cap", -1)), complete)


func _cover_texture() -> Texture2D:
	var path := String(_model.get("art_path", "res://assets/ui/annual_chronicle/stone.png"))
	var crop := path.trim_suffix(".png") + "_cutout.tres"
	if ResourceLoader.exists(crop):
		var atlas := load(crop) as Texture2D
		if atlas != null:
			return atlas
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


# ── 版式：一条纵向预算 ──────────────────────────────────────────────────────

## 间隙权重：报头与短线要贴在一起，国名与印章之间才松开。
const GAP_WEIGHTS_BASE := [0.55, 0.25, 0.80, 1.15, 0.95]
const MIN_GAP := 18.0
const MAX_GAP := 56.0


func _relayout() -> void:
	if _art == null:
		return
	var viewport: Vector2 = get_viewport_rect().size
	if viewport.y < 8.0:
		return
	# 宽度与版心一律取自令牌 —— 封面和正文必须落在同一列上，
	# 否则"一张纸"就断成两段版式。
	var width: float = AnnualReportTokens.paper_width(viewport)
	var pad: float = AnnualReportTokens.paper_padding(viewport)
	var inner: float = maxf(96.0, width - pad * 2.0)
	var art_height: float = clampf(viewport.y * 0.345, 150.0, 420.0)
	var title_size: int = AnnualReportTokens.cover_title_size(width)
	var country_size: int = int(clampf(width * 0.034, 16.0, 29.0))
	var seal: float = AnnualReportTokens.cover_seal_size(width)
	var figure_size: int = AnnualReportTokens.cover_figure_size(width)
	# 页脚那一条是浮在纸上的，封面最后一行的位置必须让开它。
	var bottom_pad: float = maxf(AnnualReportTokens.FOOTER_HEIGHT + 8.0,
		clampf(viewport.y * 0.038, 12.0, 44.0))

	var title_height: float = _measure_title(title_size)
	var country_height: float = float(country_size) * 1.34 * float(_country_lines(_country.text, country_size, inner))
	var figure_height: float = float(figure_size) * 1.20 + 36.0
	# 封面就是纸的第一屏：一屏之外的东西读者看不到，等于没有。
	# "一屏"现在是纸的可见高度（整屏减去卷首那段桌面），由编排名给。
	var cap: float = _page_cap if _page_cap > 8.0 else viewport.y

	# 主脉只有五块：眉题 · 报头 · 短线 · 国名 · 印章，末尾一行提示。
	var plan: Dictionary = _plan(art_height, title_height, country_height, seal, figure_height, false, bottom_pad)
	var required: float = float(plan.fixed) + MIN_GAP * float(plan.units)

	# 三个大数是"有地方才放"的补白：整块塞得下才放，塞不下就撤掉，
	# 绝不为了它们把报头压小、把版画压成一条横带。
	var with_figures: Dictionary = _plan(art_height, title_height, country_height, seal, figure_height, true, bottom_pad)
	var figures_shown: bool = float(with_figures.fixed) + MIN_GAP * float(with_figures.units) <= cap
	if figures_shown:
		plan = with_figures
		required = float(plan.fixed) + MIN_GAP * float(plan.units)

	# 主脉本身就放不下时：先把版画收到底，再动报头。
	# 报头是这一页唯一的焦点，它能不动就不动 —— 缺的几十像素从插画上扣，
	# 读者不会去数插画有多高，但一眼就能看出标题小了一档。
	var art_floor: float = maxf(112.0, viewport.y * 0.185)
	var stage := 0
	while required > cap and stage <= 1:
		var acted := false
		if stage == 0:
			if art_height > art_floor:
				art_height = maxf(art_floor, art_height - 14.0)
				acted = true
			else:
				stage = 1
		else:
			if title_size > 72:
				title_size -= 6
				title_height = _measure_title(title_size)
				acted = true
			else:
				stage = 2
		if not acted:
			continue
		plan = _plan(art_height, title_height, country_height, seal, figure_height, figures_shown, bottom_pad)
		required = float(plan.fixed) + MIN_GAP * float(plan.units)

	var page_height: float = maxf(cap, required)
	_page_height = page_height
	custom_minimum_size = Vector2(0.0, page_height)
	var gap: float = clampf((page_height - float(plan.fixed)) / maxf(1.0, float(plan.units)), MIN_GAP, MAX_GAP)
	var weights: Array = plan.weights
	var heights: Array = plan.heights

	# 评级标尺只在正文第九章出现，封面不再重复一遍。
	_ruler.visible = false
	for i in 3:
		_numerals[i].visible = figures_shown
		_captions[i].visible = figures_shown
		_deltas[i].visible = figures_shown and not _deltas[i].text.is_empty()

	# ── 版画：左右贴纸缘，下沿化进纸里 ──
	_art_clip.position = Vector2.ZERO
	_art_clip.size = Vector2(width, art_height)
	var art_size := Vector2(1395.0, 921.0)
	if _art.texture != null:
		var texture_size: Vector2 = _art.texture.get_size()
		if texture_size.x > 1.0 and texture_size.y > 1.0:
			art_size = texture_size
	var era: Dictionary = AnnualReportTokens.era_layout(int(_model.get("era_index", 0)))
	var art_scale: float = maxf(width / art_size.x, art_height / art_size.y) * float(era.get("scale", 1.0))
	var scaled: Vector2 = art_size * art_scale
	_art.position = Vector2((width - scaled.x) * 0.5, (art_height - scaled.y) * 0.42)
	_art.size = scaled
	# 下沿不能用一块纸色矩形盖住 —— 纸本身是有纹理的，盖上去就是一块平斑。
	# 改成把版画自己的 alpha 化掉，让底下的纸真的露出来。
	var clip_bottom: float = art_height - _art.position.y
	_art_material.set_shader_parameter("fade_from", clip_bottom - art_height * 0.62)
	_art_material.set_shader_parameter("fade_to", clip_bottom - art_height * 0.02)
	_wash.position = Vector2.ZERO
	_wash.size = _art_clip.size
	# 纸雾改成"上浓下透"：给版画压一层暖调，越往下越让位给纸。
	_wash_material.set_shader_parameter("flip", 1.0)
	_wash_material.set_shader_parameter("feather", 0.95)
	_wash_material.set_shader_parameter("strength", clampf(0.34 + float(era.get("wash", 0.70)) * 0.10, 0.34, 0.46))

	# ── 依链式布局落位 ──
	# 链：0 眉题 · 1 报头 · 2 短线 · 3 国名 · 4 印章 · [5 大数] · 末位 提示
	var index_figures: int = 5
	var index_cue: int = 5 + (1 if figures_shown else 0)
	var cursor: float = art_height + gap * float(weights[0])

	_kicker.position = Vector2(pad, cursor)
	_kicker.size = Vector2(inner, float(heights[0]))
	cursor += float(heights[0]) + gap * float(weights[1])

	_apply_title_metrics(title_size)
	_title.position = Vector2(pad, cursor)
	_title.size = Vector2(inner, title_height + 4.0)
	_title_material.set_shader_parameter("bounds", _title.size)
	cursor += float(heights[1]) + gap * float(weights[2])

	_rule.position = Vector2(pad, cursor)
	_rule.size = Vector2(clampf(float(title_size) * 1.55, 64.0, 240.0), float(heights[2]))
	cursor += float(heights[2]) + gap * float(weights[3])

	_country.add_theme_font_size_override("font_size", country_size)
	_country.add_theme_constant_override("line_spacing", -int(round(float(country_size) * 0.1)))
	_country.position = Vector2(pad, cursor)
	_country.size = Vector2(inner, country_height + 4.0)
	cursor += float(heights[3]) + gap * float(weights[4])

	_seal.position = Vector2(pad, cursor)
	_seal.size = Vector2(seal, seal)
	_seal.pivot_offset = _seal.size * 0.5
	_grade.add_theme_font_size_override("font_size", int(round(seal * 0.42)))
	var score_size: int = int(clampf(seal * 0.36, 22.0, 54.0))
	_score.add_theme_font_size_override("font_size", score_size)
	var score_x: float = pad + seal + 20.0
	var score_width: float = maxf(60.0, inner - seal - 20.0)
	_score.position = Vector2(score_x, cursor + seal * 0.10)
	_score.size = Vector2(score_width, float(score_size) * 1.24)
	_score_unit.position = Vector2(score_x, cursor + seal * 0.10 + float(score_size) * 1.14)
	_score_unit.size = Vector2(score_width, 20.0)
	_reward.position = Vector2(score_x, cursor + seal * 0.10 + float(score_size) * 1.14 + 24.0)
	_reward.size = Vector2(score_width, 22.0)
	cursor += float(heights[4]) + gap * float(weights[5])

	if figures_shown:
		var column: float = inner / 3.0
		for i in 3:
			var fit: int = _fit_figure_size(_numerals[i].text, column - 12.0, figure_size)
			_numerals[i].add_theme_font_size_override("font_size", fit)
			_numerals[i].position = Vector2(pad + column * float(i), cursor)
			_numerals[i].size = Vector2(column - 12.0, float(fit) * 1.20)
			_captions[i].position = Vector2(pad + column * float(i), cursor + float(fit) * 1.02)
			_captions[i].size = Vector2(column - 12.0, 18.0)
			_deltas[i].position = Vector2(pad + column * float(i), cursor + float(fit) * 1.02 + 17.0)
			_deltas[i].size = Vector2(column - 12.0, 18.0)
		cursor += float(heights[index_figures]) + gap * float(weights[index_figures + 1])

	_cue.position = Vector2(pad, cursor)
	_cue.size = Vector2(inner, float(heights[index_cue]))


## 一条纵向链：每一块的高度，以及块与块之间的间隙权重（含纸顶到第一块）。
func _plan(art_height: float, title_height: float, country_height: float, seal: float,
		figure_height: float, figures_shown: bool, bottom_pad: float) -> Dictionary:
	var heights: Array = [18.0, title_height, 2.0, country_height, seal]
	var weights: Array = GAP_WEIGHTS_BASE.duplicate()
	if figures_shown:
		heights.append(figure_height)
		weights.append(1.15)
	heights.append(18.0)   # cue
	weights.append(0.95)
	var fixed: float = art_height + bottom_pad
	for value in heights:
		fixed += float(value)
	var units := 0.0
	for value in weights:
		units += float(value)
	return {"heights": heights, "weights": weights, "fixed": fixed, "units": units}


func _measure_title(size_px: int) -> float:
	var font: Font = UITokens.annual_font("display")
	return font.get_height(size_px) * 2.0 - round(float(size_px) * 0.16)


func _apply_title_metrics(size_px: int) -> void:
	var spacing: int = -int(round(float(size_px) * 0.16))
	_title.add_theme_font_size_override("font_size", size_px)
	_title.add_theme_constant_override("line_spacing", spacing)
	_title.add_theme_constant_override("outline_size", int(round(float(size_px) * 0.055)))


func _country_lines(text: String, size_px: int, available: float) -> int:
	if text.is_empty() or available <= 1.0:
		return 1
	var font: Font = UITokens.annual_font("display_soft")
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x
	return clampi(int(ceilf(width / available)), 1, 2)


func _fit_figure_size(text: String, max_width: float, desired: int) -> int:
	if text.is_empty() or max_width <= 1.0:
		return desired
	var font: Font = UITokens.annual_font("numeral")
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, desired).x
	if width <= max_width:
		return desired
	return maxi(24, int(float(desired) * max_width / maxf(width, 1.0)))


# ── 开场：2.6s 落墨时间线 ──────────────────────────────────────────────────

func play_opening() -> void:
	if _art == null:
		_ready()
	finish_opening(false)
	if UIAnimation.reduced_motion():
		modulate.a = 1.0
		_settle_visuals()
		return
	var top_grade: bool = int(_model.get("grade_index", 6)) <= 1 and bool(_model.get("complete", false))

	_art.material = _art_material
	_title.material = _title_material
	modulate.a = 0.0
	_art_material.set_shader_parameter("bleed", 0.0)
	_title_material.set_shader_parameter("bleed", 0.0)
	_seal_material.set_shader_parameter("press", 0.0)
	_seal_material.set_shader_parameter("ring", 0.0)
	_seal_material.set_shader_parameter("glint", -1.0)
	_wash.modulate.a = 0.0
	_rule.size = Vector2(0.0, _rule.size.y)
	_country.modulate.a = 0.0
	_kicker.modulate.a = 0.0
	_score.modulate.a = 0.0
	_score_unit.modulate.a = 0.0
	_reward.modulate.a = 0.0
	_ruler.modulate.a = 0.0
	_seal.modulate.a = 0.0
	_seal.scale = Vector2(1.07, 1.07)
	_cue.modulate.a = 0.0
	for i in 3:
		_numerals[i].modulate.a = 0.0
		_captions[i].modulate.a = 0.0
		_deltas[i].modulate.a = 0.0

	var rule_width: float = _rule.size.x if _rule.size.x > 1.0 else 72.0
	_opening = create_tween().set_parallel(true)
	_opening.tween_property(self, "modulate:a", 1.0, 0.18).set_delay(0.0)
	_opening.tween_property(_art_material, "shader_parameter/bleed", 1.2, 0.62) \
		.set_delay(0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_opening.tween_property(_wash, "modulate:a", 1.0, 0.44).set_delay(0.30).set_trans(Tween.TRANS_SINE)
	_opening.tween_property(_kicker, "modulate:a", 1.0, 0.24).set_delay(0.44)
	_opening.tween_property(_title_material, "shader_parameter/bleed", 1.2, 0.52) \
		.set_delay(0.60).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_opening.tween_property(_rule, "size:x", rule_width, 0.22).set_delay(0.98).set_trans(Tween.TRANS_CUBIC)
	_opening.tween_property(_country, "modulate:a", 1.0, 0.34).set_delay(1.16).set_trans(Tween.TRANS_SINE)
	_opening.tween_property(_seal, "modulate:a", 1.0, 0.20).set_delay(1.28)
	_opening.tween_property(_seal_material, "shader_parameter/press", 1.0, 0.28) \
		.set_delay(1.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_opening.tween_property(_seal, "scale", Vector2.ONE, 0.30).set_delay(1.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_opening.tween_property(_seal_material, "shader_parameter/ring", 1.0, 0.24) \
		.set_delay(1.38).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if top_grade:
		_opening.tween_property(_seal_material, "shader_parameter/glint", 1.4, 0.26) \
			.set_delay(1.50).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT).from(-0.4)
	_opening.tween_property(_score, "modulate:a", 1.0, 0.30).set_delay(1.58)
	_opening.tween_property(_score_unit, "modulate:a", 1.0, 0.30).set_delay(1.66)
	var final_score: float = float(_model.get("score", 0.0))
	_opening.tween_method(func(value: float) -> void: _score.text = "%.2f" % value,
		0.0, final_score, 0.40).set_delay(1.58).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_opening.tween_property(_ruler, "modulate:a", 1.0 if bool(_model.get("complete", false)) else 0.42, 0.30).set_delay(1.62)
	_ruler.replay_growth()
	_opening.tween_callback(_restart_ruler).set_delay(1.62)
	for i in 3:
		var delay: float = 2.02 + 0.09 * float(i)
		_opening.tween_property(_numerals[i], "modulate:a", 1.0, 0.20).set_delay(delay)
		_opening.tween_property(_captions[i], "modulate:a", 1.0, 0.20).set_delay(delay + 0.04)
		_opening.tween_property(_deltas[i], "modulate:a", 1.0, 0.20).set_delay(delay + 0.06)
	_opening.tween_property(_reward, "modulate:a", 1.0, 0.28).set_delay(2.10)
	_opening.tween_property(_cue, "modulate:a", 1.0, 0.24).set_delay(2.24)
	if top_grade:
		_opening.tween_callback(_gather_reward_motes).set_delay(2.40)
	_opening.tween_callback(func() -> void: finish_opening()).set_delay(2.60)


## 立刻落到终态。`clear_material` 为假时保留 shader（长卷还要用它做纸面压实）。
##
## 注意只摘报头的材质：版画那道"下沿化进纸里"的羽化就活在自己的材质里，
## 摘掉它版画就会露出一条硬直的下沿。
func finish_opening(clear_material: bool = true) -> void:
	if _opening != null and _opening.is_valid():
		_opening.kill()
	_opening = null
	if _art == null:
		return
	modulate.a = 1.0
	_settle_visuals()
	if clear_material:
		_title.material = null


func _settle_visuals() -> void:
	_wash.modulate.a = 1.0
	_kicker.modulate.a = 1.0
	_country.modulate.a = 1.0
	_title.modulate.a = 1.0
	_score.modulate.a = 1.0
	_score_unit.modulate.a = 1.0
	_reward.modulate.a = 1.0
	_seal.modulate.a = 1.0
	_seal.scale = Vector2.ONE
	_ruler.modulate.a = 1.0 if bool(_model.get("complete", false)) else 0.42
	_cue.modulate.a = 1.0
	for i in 3:
		_numerals[i].modulate.a = 1.0
		_captions[i].modulate.a = 1.0
		_deltas[i].modulate.a = 1.0
	for child in _reward.get_children():
		if child is ColorRect:
			var flight: Tween = child.get_meta("flight", null)
			if flight != null and flight.is_valid():
				flight.kill()
			child.queue_free()
	_score.text = "%.2f" % float(_model.get("score", 0.0))
	if not bool(_model.get("complete", false)):
		_score.text = "—"
	if _seal_material != null:
		_seal_material.set_shader_parameter("press", 1.0)
		_seal_material.set_shader_parameter("ring", 0.0)
		_seal_material.set_shader_parameter("glint", -1.0)
	if _art_material != null:
		_art_material.set_shader_parameter("bleed", 1.2)
	if _title_material != null:
		_title_material.set_shader_parameter("bleed", 1.2)


func _restart_ruler() -> void:
	if _ruler == null or not is_instance_valid(_ruler):
		return
	_ruler.set_data(float(_model.get("score", 0.0)), String(_model.get("grade", "—")),
		int(_model.get("grade_cap", -1)), bool(_model.get("complete", false)))


func _gather_reward_motes() -> void:
	if UIAnimation.reduced_motion() or not is_instance_valid(_reward):
		return
	var target := Vector2(_reward.size.x - 6.0, _reward.size.y * 0.5)
	for i in 12:
		var mote := RewardMoteScene.instantiate() as ColorRect
		if mote == null:
			return
		mote.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mote.size = Vector2(2, 2)
		mote.color = UITokens.CHRONICLE_BRASS
		mote.position = target + Vector2.from_angle(float(i) * TAU / 12.0) * (22.0 + float(i % 4) * 9.0)
		_reward.add_child(mote)
		var flight := create_tween().set_parallel(true)
		mote.set_meta("flight", flight)
		flight.tween_property(mote, "position", target, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		flight.tween_property(mote, "modulate:a", 0.0, 0.30)
		flight.chain().tween_callback(mote.queue_free)


# ── 输入：点击 / 手柄 A 交棒给正文 ─────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		preload("res://scripts/ui/ui_audio_feedback.gd").play_for(self, &"page")
		begin_requested.emit()
		accept_event()
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index in [JOY_BUTTON_A, JOY_BUTTON_DPAD_DOWN]:
			preload("res://scripts/ui/ui_audio_feedback.gd").play_for(self, &"page")
			begin_requested.emit()
			accept_event()


# ── 对外取用 ────────────────────────────────────────────────────────────────

func art() -> TextureRect:
	if _art == null:
		_ready()
	return _art


func stamp() -> Control:
	if _seal == null:
		_ready()
	return _seal


func seal_ink() -> TextureRect:
	return _seal_art


func ruler() -> AnnualGradeRuler:
	return _ruler


func page_height() -> float:
	return _page_height
