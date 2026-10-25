extends Control
class_name ProcurementBudgetSlider

# Technology-point procurement expressed as a share of the treasury per day.
# The far-left stop is "off", so one drag covers the whole policy and there is
# nothing to submit afterwards.

signal budget_previewed(enabled: bool, daily_cash_limit: int)
signal budget_committed(enabled: bool, daily_cash_limit: int)

const CASH_SCALE := 10000.0
const MAX_TREASURY_SHARE := 0.10
const TRACK_TOP := 61.0
const TRACK_HEIGHT := 8.0
const HIT_BAND := 13.0
const GRABBER_RADIUS := 6.5
const TICKS := [0.0, 0.25, 0.5, 0.75, 1.0]

var _ratio := 0.0
var _treasury := 0
var _limit := 0
var _dragging := false
var _hovered := false
var _track_style := StyleBoxFlat.new()


func _ready() -> void:
	_track_style.set_corner_radius_all(int(TRACK_HEIGHT * 0.5))
	_track_style.anti_aliasing = true
	custom_minimum_size = Vector2(0.0, 102.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "拖到最左端即关闭自动采购；松手立即生效"


func set_state(enabled: bool, daily_cash_limit: int, treasury_cash: int) -> void:
	_treasury = maxi(0, treasury_cash)
	if _dragging:
		return
	_limit = maxi(0, daily_cash_limit)
	_ratio = 0.0 if not enabled or _limit <= 0 else clampf(
		float(_limit) / maxf(1.0, float(_treasury) * MAX_TREASURY_SHARE), 0.0, 1.0)
	queue_redraw()


func daily_cash_limit() -> int:
	return _limit


func is_enabled() -> bool:
	return _ratio > 0.0 and _limit > 0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if absf(button.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) > HIT_BAND:
				return
			_dragging = true
			_apply_position(button.position.x)
			accept_event()
			return
		if _dragging:
			_dragging = false
			budget_committed.emit(is_enabled(), _limit)
			queue_redraw()
			accept_event()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging:
			_apply_position(motion.position.x)
			accept_event()
			return
		var inside := absf(motion.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) <= HIT_BAND
		if inside != _hovered:
			_hovered = inside
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hovered:
		_hovered = false
		queue_redraw()


func _apply_position(x: float) -> void:
	var span := maxf(1.0, size.x - GRABBER_RADIUS * 2.0)
	_ratio = clampf((x - GRABBER_RADIUS) / span, 0.0, 1.0)
	_limit = int(round(_ratio * MAX_TREASURY_SHARE * float(_treasury)))
	queue_redraw()
	budget_previewed.emit(is_enabled(), _limit)


func _grabber_x() -> float:
	return GRABBER_RADIUS + _ratio * maxf(1.0, size.x - GRABBER_RADIUS * 2.0)


func _draw() -> void:
	var enabled := is_enabled()
	var sans := UITokens.dossier_font("sans")
	var strong := UITokens.dossier_font("sans_strong")
	var serif := UITokens.dossier_font("numeral")
	_draw_glyph(IconCatalog.good_semantic("technology_points"), Vector2(2.0, 23.0), 24,
		UITokens.DOSSIER_INK_SOFT)
	draw_string(strong, Vector2(32.0, 22.0), "国库采购科技值",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, UITokens.DOSSIER_INK)
	var value_text := "已关闭" if not enabled else "每日 %s" % \
		UITokens.format_compact_number_cn(float(_limit) / CASH_SCALE, 2)
	var value_extent := serif.get_string_size(
		value_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18)
	draw_string(serif, Vector2(size.x - value_extent.x - 1.0, 47.0), value_text,
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
	draw_string(sans, Vector2(1.0, 96.0), _preview_text(),
		HORIZONTAL_ALIGNMENT_LEFT, size.x - 2.0, 15, UITokens.DOSSIER_INK_MUTED)


func _preview_text() -> String:
	if not is_enabled():
		return "仅用自有产出，不动国库"
	if _limit <= 0 or _treasury <= 0:
		return "国库不足，无法采购"
	# Once the treasury covers a year of purchases the exact day count stops
	# informing any decision, so it collapses into a single reassurance.
	var share := MAX_TREASURY_SHARE * _ratio * 100.0
	var days := int(floor(float(_treasury) / float(_limit)))
	if days > 365:
		return "占国库 %.1f%%/日 · 国库充裕" % share
	return "占国库 %.1f%%/日 · 可支撑 %d 天" % [share, days]


func _draw_glyph(semantic: StringName, baseline: Vector2, glyph_size: int,
		colour: Color) -> void:
	IconCatalog.draw_icon(self, semantic,
		Rect2(baseline - Vector2(0, glyph_size * 0.84), Vector2.ONE * glyph_size), colour.a)
