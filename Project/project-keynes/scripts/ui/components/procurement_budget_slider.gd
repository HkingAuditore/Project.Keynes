extends Control
class_name ProcurementBudgetSlider

# 国家购买中科技占比：国家购买预算（国库面板设定的每日国库份额）里有多少
# 投入科技值采购，0–100%（research_share_bp 0..10000）。最左端 = 0%，即不购买
# 科技值；一次拖动就是整条政策，松手立即提交，没有额外按钮。
# 每日科技预算 = 国家每日购买额 × 占比。

signal share_previewed(research_share_bp: int)
signal share_committed(research_share_bp: int)

const CASH_SCALE := 10000.0
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const MAX_SHARE_BP := 10000
## 1% 一档。
const STEP_BP := 100
const TRACK_TOP := 61.0
const TRACK_HEIGHT := 8.0
const HIT_BAND := 13.0
const GRABBER_RADIUS := 6.5
const TICKS := [0.0, 0.25, 0.5, 0.75, 1.0]

var _share_bp := 0
var _national_daily := 0
var _national_enabled := true
var _dragging := false
var _hovered := false
var _track_style := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	_track_style.set_corner_radius_all(int(TRACK_HEIGHT * 0.5))
	_track_style.anti_aliasing = true
	custom_minimum_size = Vector2(0.0, 102.0)
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = "国家购买预算中投入科技值采购的比例；拖到最左端即不购买科技值，松手立即生效。" \
		+ "国家购买总额在「国民经济 · 国库」中设定。"


## research_share_bp：科技占比 0..10000；national_daily：每日国家购买额
## （MONEY_SCALE 现金）；national_enabled：国库份额是否大于 0。
func set_state(research_share_bp: int, national_daily: int,
		national_enabled: bool = true) -> void:
	_national_daily = maxi(0, national_daily)
	_national_enabled = national_enabled
	if _dragging:
		queue_redraw()
		return
	_share_bp = clampi(research_share_bp, 0, MAX_SHARE_BP)
	queue_redraw()


func research_share_bp() -> int:
	return _share_bp


## 折算后的每日科技预算（MONEY_SCALE 现金）。
func daily_research_budget() -> int:
	if not _national_enabled:
		return 0
	return int(round(float(_national_daily) * float(_share_bp) / float(MAX_SHARE_BP)))


func is_enabled() -> bool:
	return _share_bp > 0


func _hit_band() -> float:
	return maxf(HIT_BAND, TouchUI.dense_units() * 0.5) if TouchUI.is_touch() else HIT_BAND


func _gui_input(event: InputEvent) -> void:
	var hit_band := _hit_band()
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if absf(button.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) > hit_band:
				return
			_dragging = true
			_apply_position(button.position.x)
			accept_event()
			return
		if _dragging:
			_dragging = false
			if TouchUI.is_touch():
				_hovered = false
			share_committed.emit(_share_bp)
			queue_redraw()
			accept_event()
		elif TouchUI.is_touch() and _hovered:
			_hovered = false
			queue_redraw()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging:
			_apply_position(motion.position.x)
			accept_event()
			return
		var inside := absf(motion.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) <= hit_band
		if inside != _hovered:
			_hovered = inside
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hovered:
		_hovered = false
		queue_redraw()


func _apply_position(x: float) -> void:
	var span := maxf(1.0, size.x - GRABBER_RADIUS * 2.0)
	var ratio := clampf((x - GRABBER_RADIUS) / span, 0.0, 1.0)
	_share_bp = clampi(int(round(ratio * float(MAX_SHARE_BP) / float(STEP_BP))) * STEP_BP,
		0, MAX_SHARE_BP)
	queue_redraw()
	share_previewed.emit(_share_bp)


func _ratio() -> float:
	return float(_share_bp) / float(MAX_SHARE_BP)


func _grabber_x() -> float:
	return GRABBER_RADIUS + _ratio() * maxf(1.0, size.x - GRABBER_RADIUS * 2.0)


func _draw() -> void:
	var enabled := is_enabled()
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	var serif := UITokens.dossier_font("numeral")
	_draw_glyph(IconCatalog.good_semantic("technology_points"), Vector2(2.0, 23.0), 24,
		UITokens.DOSSIER_INK_SOFT)
	draw_string(strong, Vector2(32.0, 22.0), "国家购买中科技占比",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, UITokens.DOSSIER_INK)
	var label_text := value_text()
	var value_extent := serif.get_string_size(
		label_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18)
	draw_string(serif, Vector2(size.x - value_extent.x - 1.0, 47.0), label_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18,
		UITokens.DOSSIER_OXBLOOD if enabled else UITokens.DOSSIER_INK_MUTED)
	var track := Rect2(GRABBER_RADIUS, TRACK_TOP, maxf(1.0, size.x - GRABBER_RADIUS * 2.0),
		TRACK_HEIGHT)
	_track_style.bg_color = UITokens.DOSSIER_TRACK
	draw_style_box(_track_style, track)
	for tick in TICKS:
		var tick_x := track.position.x + track.size.x * float(tick)
		draw_line(Vector2(tick_x, track.end.y + 2.0), Vector2(tick_x, track.end.y + 5.0),
			UITokens.DOSSIER_RULE, 1.0)
	if enabled:
		_track_style.bg_color = UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_OXBLOOD, 0.35)
		draw_style_box(_track_style, Rect2(track.position,
			Vector2(maxf(TRACK_HEIGHT, _grabber_x() - track.position.x), track.size.y)))
	var grabber := Vector2(_grabber_x(), TRACK_TOP + TRACK_HEIGHT * 0.5)
	var radius := GRABBER_RADIUS + (1.0 if _dragging or _hovered else 0.0)
	draw_circle(grabber, radius + 1.0, Color(UITokens.DOSSIER_INK, 0.35))
	draw_circle(grabber, radius, UITokens.DOSSIER_PAPER)
	draw_circle(grabber, radius - 2.5, UITokens.DOSSIER_OXBLOOD if enabled \
		else UITokens.DOSSIER_UMBER)
	_draw_preview(sans, Vector2(1.0, 96.0), 15)


func value_text() -> String:
	return "%d%%" % int(round(_ratio() * 100.0)) if is_enabled() else "不购买"


## 「占国家购买 40% · 每日 [金币]1.2万」；金额部分在绘制时由金币图标承担单位。
func preview_text() -> String:
	if not is_enabled():
		return "仅用自有产出，不购买科技值"
	if not _national_enabled:
		return "占国家购买 %d%% · 国家购买预算已关闭" % int(round(_ratio() * 100.0))
	return "占国家购买 %d%% · 每日 %s" % [int(round(_ratio() * 100.0)),
		UITokens.format_compact_number_cn(float(daily_research_budget()) / CASH_SCALE, 2)]


func _draw_preview(font: Font, baseline: Vector2, font_size: int) -> void:
	var colour := UITokens.DOSSIER_INK_MUTED
	if not is_enabled() or not _national_enabled:
		draw_string(font, baseline, preview_text(), HORIZONTAL_ALIGNMENT_LEFT,
			size.x - 2.0, font_size, colour)
		return
	var head := "占国家购买 %d%% · 每日 " % int(round(_ratio() * 100.0))
	draw_string(font, baseline, head, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, colour)
	var x := baseline.x + font.get_string_size(head, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		font_size).x
	x += MoneyDisplay.draw_on_baseline(self, Vector2(x, baseline.y), font_size, font)
	draw_string(font, Vector2(x, baseline.y), UITokens.format_compact_number_cn(
		float(daily_research_budget()) / CASH_SCALE, 2), HORIZONTAL_ALIGNMENT_LEFT,
		maxf(1.0, size.x - x - 1.0), font_size, colour)


func _draw_glyph(semantic: StringName, baseline: Vector2, glyph_size: int,
		colour: Color) -> void:
	IconCatalog.draw_icon(self, semantic,
		Rect2(baseline - Vector2(0, glyph_size * 0.84), Vector2.ONE * glyph_size), colour.a)
