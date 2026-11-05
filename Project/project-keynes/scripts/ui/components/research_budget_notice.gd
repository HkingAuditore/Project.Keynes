extends Control
class_name ResearchBudgetNotice

## 科技工作区里的「预算指引」撕纸便笺。
##
## 科技投入份额已经统一到 国民经济 · 国库 的预算卷宗里，这里不再提供第二条
## 可拖的滑条——同一份政策有两个写入口会让玩家拖完一边、另一边还显示旧值。
## 便笺只负责把当前份额读清楚，并给一个直达预算卷宗的入口。

signal open_budget_requested()

const NOTICE_HEIGHT := 96.0
const CASH_SCALE := 10000.0
const TORN_DEPTH := 3.0

var _share_bp := 0
var _national_daily := 0
var _national_enabled := true
var _button: Button = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(0.0, NOTICE_HEIGHT)
	_button = Button.new()
	_button.name = "OpenBudget"
	_button.text = "前往预算调配"
	_button.focus_mode = Control.FOCUS_ALL
	_button.theme_type_variation = &"PKTabButton"
	_button.pressed.connect(func() -> void: open_budget_requested.emit())
	add_child(_button)


func _ready() -> void:
	if not resized.is_connected(_layout_button):
		resized.connect(_layout_button)
	_layout_button()


func _layout_button() -> void:
	if _button == null:
		return
	_button.position = Vector2(10.0, maxf(4.0, size.y - 32.0))
	_button.size = Vector2(clampf(size.x - 20.0, 96.0, 168.0), 26.0)
	_button.tooltip_text = "打开 国民经济 · 国库，在预算卷宗里调整科技、时代收购、开拓与军事份额"


func set_state(research_share_bp: int, national_daily: int,
		national_enabled: bool = true) -> void:
	_share_bp = clampi(research_share_bp, 0, 10000)
	_national_daily = maxi(0, national_daily)
	_national_enabled = national_enabled
	queue_redraw()


func research_share_bp() -> int:
	return _share_bp


func daily_research_budget() -> int:
	if not _national_enabled:
		return 0
	return int(round(float(_national_daily) * float(_share_bp) / 10000.0))


func value_text() -> String:
	return "%.0f%%" % (float(_share_bp) / 100.0)


func preview_text() -> String:
	if not _national_enabled:
		return "国家购买预算已关闭，科技值暂不采购"
	return "占国家购买 %s · 每日 %s" % [value_text(),
		UITokens.format_compact_number_cn(
			float(daily_research_budget()) / CASH_SCALE, 2)]


func _draw() -> void:
	if size.x < 20.0 or size.y < 20.0:
		return
	_draw_paper()
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	var numeral := UITokens.dossier_font("numeral")
	var ink := Color(UITokens.DOSSIER_INK, 1.0)
	var muted := Color(UITokens.DOSSIER_INK_MUTED, 1.0)
	var value := value_text()
	var value_width := numeral.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, 17).x
	draw_string(strong, Vector2(12.0, 20.0), "科技投入份额",
		HORIZONTAL_ALIGNMENT_LEFT, maxf(40.0, size.x - value_width - 30.0), 14, ink)
	draw_string(numeral, Vector2(maxf(12.0, size.x - value_width - 12.0), 20.0),
		value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17,
		Color(UITokens.DOSSIER_OXBLOOD, 1.0) if _share_bp > 0 else muted)
	draw_string(sans, Vector2(12.0, 40.0), preview_text(),
		HORIZONTAL_ALIGNMENT_LEFT, maxf(40.0, size.x - 24.0), 13,
		Color(UITokens.DOSSIER_INK_SOFT, 1.0))
	draw_string(sans, Vector2(12.0, 58.0),
		"与时代收购、开拓、军事预算同在 国民经济 · 国库的预算卷宗里调整",
		HORIZONTAL_ALIGNMENT_LEFT, maxf(40.0, size.x - 24.0), 12, muted)


func _draw_paper() -> void:
	var paper := _torn_polygon()
	var shadow := PackedVector2Array()
	for point in paper:
		shadow.append(point + Vector2(1.2, 1.6))
	draw_colored_polygon(shadow, Color(UITokens.DOSSIER_INK, 0.10))
	draw_colored_polygon(paper, UITokens.DOSSIER_PAPER)
	var outline := PackedVector2Array(paper)
	outline.append(paper[0])
	draw_polyline(outline, Color(UITokens.DOSSIER_OXBLOOD, 0.20), 1.0, true)
	draw_rect(Rect2(0.0, 0.0, 3.0, size.y - TORN_DEPTH),
		Color(UITokens.DOSSIER_SLATE, 0.75))


func _torn_polygon() -> PackedVector2Array:
	var width := size.x
	var bottom := size.y - TORN_DEPTH
	var points := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(width, 0.0), Vector2(width, bottom)])
	var steps := maxi(5, int(width / 26.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x2D51 + steps
	for index in range(steps):
		var t := 1.0 - float(index + 1) / float(steps + 1)
		points.append(Vector2(width * t, bottom + TORN_DEPTH * rng.randf_range(0.3, 1.0)))
	points.append(Vector2(0.0, bottom + TORN_DEPTH * 0.5))
	return points
