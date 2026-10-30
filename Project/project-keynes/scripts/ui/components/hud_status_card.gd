extends Control
class_name HudStatusCard

## 顶栏纸签的悬浮卡：国库页给当日收支结构，人口页给阶层构成与各阶层福祉。
##
## 排版规则：
## - 卡宽固定，高度由内容撑开（构成条 + 若干行 + 页脚），不写死像素；
## - 两种页面共用同一套页头和页脚，只切换中间的主体，所以两张卡读起来是一家人；
## - 整张卡 mouse_filter = IGNORE：它只是提示，不能抢地图点击，也不能因为指针
##   移进卡里就把纸签的 hover 判成离开。
## - 卡片贴在被悬浮的纸签下方，越界时自动收进视口，放不下就翻到纸签上方。

const WIDTH := 400.0
const ANCHOR_GAP := 8.0
const EDGE_MARGIN := 8.0
const FADE_IN_SEC := 0.12
const FADE_OUT_SEC := 0.09
const SLIDE_PX := 6.0

@onready var _shadow: ColorRect = $Shadow
@onready var _paper: PanelContainer = $Paper
@onready var _title: Label = %TitleLabel
@onready var _icon: IconBadge = %HeaderIcon
## 读数前的金币图标：国库页（金额）显示，人口页（人数）隐藏。
@onready var _value_icon: TextureRect = %ValueIcon
@onready var _value: Label = %ValueLabel
@onready var _meta: Label = %MetaLabel
@onready var _treasury_body: VBoxContainer = %TreasuryBody
@onready var _income_bar: DossierStackedBar = %IncomeBar
@onready var _expense_bar: DossierStackedBar = %ExpenseBar
@onready var _net_row: HBoxContainer = %NetRow
@onready var _net_icon: TextureRect = %NetIcon
@onready var _net_value: Label = %NetValue
@onready var _treasury_note: Label = %TreasuryNote
@onready var _population_body: VBoxContainer = %PopulationBody
@onready var _share_bar: HudShareBar = %ShareBar
@onready var _rows: VBoxContainer = %StratumRows
@onready var _population_note: Label = %PopulationNote
@onready var _footer: Label = %FooterLabel

var _kind := ""
var _tween: Tween
var _fit_generation := 0
var _anchor := Rect2()
var _signature := ""


func _ready() -> void:
	# 提示卡不参与命中测试：指针永远算在纸签上，地图点击也不会被它挡住。
	for node in find_children("*", "Control", true, false):
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_title.add_theme_font_size_override("font_size", 13)
	_title.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	# 金额只写数字，货币单位由纸贴金币承担（项目统一口径，见 MoneyDisplay）。
	MoneyDisplay.apply_icon(_value_icon, 24)
	MoneyDisplay.apply_icon(_net_icon, 14)
	_value.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_value.add_theme_font_size_override("font_size", 24)
	_value.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	_meta.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_meta.add_theme_font_size_override("font_size", 11)
	_meta.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_net_value.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_net_value.add_theme_font_size_override("font_size", 14)
	for label: Label in [_treasury_note, _population_note, _footer]:
		label.add_theme_font_override("font", UITokens.dossier_font("sans"))
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	visible = false
	if _shadow != null:
		_shadow.resized.connect(_sync_shadow)
	_sync_shadow()


## 阴影用 ideology_paper_shadow 的柔光着色器：投影面积比纸面小一圈、颜色更淡，
## 边缘是一条渐变而不是 StyleBoxFlat 那种硬边。canvas_size 必须跟着卡片尺寸走。
func _sync_shadow() -> void:
	if _shadow == null:
		return
	var material := _shadow.material as ShaderMaterial
	if material == null:
		return
	material.set_shader_parameter("canvas_size", _shadow.size)


func kind() -> String:
	return _kind


func is_open() -> bool:
	return visible and not _kind.is_empty()


## anchor 是被悬浮纸签的全局矩形；卡片贴在它下方，越界时自动收进视口。
func show_card(model: Dictionary, anchor: Rect2) -> void:
	var was_open := is_open()
	_apply(model)
	_anchor = anchor
	_fit_size()
	_position_against(anchor)
	visible = true
	_settle_layout()
	if was_open:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if UIAnimation.reduced_motion():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "modulate:a", 1.0, FADE_IN_SEC)


## 读数在悬停期间会随日结算变化：只重填内容，不重播入场、不挪位置。
func refresh_card(model: Dictionary) -> void:
	if not is_open() or String(model.get("kind", "")) != _kind:
		return
	if _data_signature(model) == _signature:
		return
	_apply(model)
	_fit_size()
	_settle_layout()


func hide_card(immediate: bool = false) -> void:
	if not visible:
		return
	_kind = ""
	_signature = ""
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if immediate or UIAnimation.reduced_motion():
		visible = false
		modulate.a = 1.0
		return
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT_SEC)
	_tween.tween_callback(func() -> void:
		if is_instance_valid(self):
			visible = false)


func _apply(model: Dictionary) -> void:
	_kind = String(model.get("kind", ""))
	_signature = _data_signature(model)
	_title.text = String(model.get("title", ""))
	_icon.set_semantic(StringName(model.get("icon", "metric.treasury")),
		UITokens.DOSSIER_BRASS)
	var shown_value := String(model.get("value", "—"))
	_value.text = shown_value
	# 只有金额读数才配金币：人口是人数，挂上金币会把「6789」读成金额。
	_value_icon.visible = bool(model.get("value_money", false)) and shown_value != "—"
	_meta.text = String(model.get("meta", ""))
	_footer.text = String(model.get("footer", ""))
	var treasury := _kind == "treasury"
	_treasury_body.visible = treasury
	_population_body.visible = not treasury
	_treasury_note.text = String(model.get("note", ""))
	_treasury_note.visible = not String(model.get("note", "")).is_empty()
	_population_note.text = String(model.get("note", ""))
	_population_note.visible = not String(model.get("note", "")).is_empty()
	if treasury:
		_apply_treasury(model)
	else:
		# 人口页没有净额行：显式收起，别让它留着上一页的可见状态。
		_net_row.visible = false
		_net_icon.visible = false
		_apply_population(model)


func _apply_treasury(model: Dictionary) -> void:
	var income: Dictionary = model.get("income_bar", {})
	var expense: Dictionary = model.get("expense_bar", {})
	_income_bar.visible = not income.is_empty()
	# 收支构成全是货币：合计与图例的数值都画金币，金额文本里不再带单位记号。
	_income_bar.set_segments(String(income.get("title", "收入构成")),
		income.get("segments", []), String(income.get("total", "")), true)
	_expense_bar.visible = not expense.is_empty()
	_expense_bar.set_segments(String(expense.get("title", "支出构成")),
		expense.get("segments", []), String(expense.get("total", "")), true)
	var has_net := not String(model.get("net_text", "")).is_empty()
	_net_row.visible = has_net
	_net_icon.visible = has_net
	_net_value.text = String(model.get("net_text", ""))
	_net_value.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if bool(model.get("net_positive", true))
		else UITokens.DOSSIER_OXBLOOD)


func _apply_population(model: Dictionary) -> void:
	var bar: Dictionary = model.get("share_bar", {})
	_share_bar.visible = not bar.is_empty()
	_share_bar.set_segments(bar.get("segments", []))
	var rows: Array = model.get("rows", [])
	var slots := _rows.get_children()
	for index in range(slots.size()):
		var row := slots[index] as HudPopulationRow
		var has_row := index < rows.size()
		row.visible = has_row
		if has_row:
			row.set_data(rows[index])


func _fit_size() -> void:
	# 高度由内容撑开：构成条的图例行数取决于实际宽度，所以要在布局落到最终宽度后
	# 再量（见 _settle_layout），这里只做一次同步测量。
	size = Vector2(WIDTH, maxf(_paper.get_combined_minimum_size().y, 96.0))
	_sync_shadow()


## 分帧再量两轮：构成条的图例在第一帧还没拿到最终宽度，只量一次会留下空白或切边。
func _settle_layout() -> void:
	_fit_generation += 1
	var generation := _fit_generation
	for _pass in range(2):
		await get_tree().process_frame
		if generation != _fit_generation or not visible:
			return
		_fit_size()
		_position_against(_anchor)


func _position_against(anchor: Rect2) -> void:
	var viewport_size := get_viewport_rect().size if is_inside_tree() else Vector2(1280.0, 720.0)
	var x := clampf(anchor.position.x, EDGE_MARGIN,
		maxf(EDGE_MARGIN, viewport_size.x - WIDTH - EDGE_MARGIN))
	var y := anchor.end.y + ANCHOR_GAP
	if y + size.y > viewport_size.y - EDGE_MARGIN:
		y = anchor.position.y - size.y - ANCHOR_GAP
	position = Vector2(x, maxf(y, EDGE_MARGIN))


func _data_signature(model: Dictionary) -> String:
	var parts := PackedStringArray([String(model.get("kind", "")),
		String(model.get("value", "")), String(model.get("meta", "")),
		String(model.get("net_text", ""))])
	for key in ["income_bar", "expense_bar", "share_bar"]:
		var bar: Dictionary = model.get(key, {})
		for segment in bar.get("segments", []):
			parts.append("%s:%s" % [String(segment.get("label", "")),
				String(segment.get("text", ""))])
	for row in model.get("rows", []):
		parts.append("%s|%s|%s|%s" % [String(row.get("name", "")),
			String(row.get("population_text", "")), String(row.get("satisfaction_text", "")),
			String(row.get("living_text", ""))])
	return "|".join(parts)
