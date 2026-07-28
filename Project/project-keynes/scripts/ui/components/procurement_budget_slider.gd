extends Control
class_name ProcurementBudgetSlider

# Technology-point procurement expressed as a share of the treasury per day.
# The far-left stop is "off", so one drag covers the whole policy and there is
# nothing to submit afterwards.

signal budget_previewed(enabled: bool, daily_cash_limit: int)
signal budget_committed(enabled: bool, daily_cash_limit: int)

const CASH_SCALE := 10000.0
const MAX_TREASURY_SHARE := 0.10
const TRACK_TOP := 27.0
const TRACK_HEIGHT := 6.0
const HIT_BAND := 13.0
const GRABBER_RADIUS := 6.5
const TICKS := [0.0, 0.25, 0.5, 0.75, 1.0]

var _ratio := 0.0
var _treasury := 0
var _limit := 0
var _dragging := false
var _hovered := false
var _label_font: Font = UITokens.font_with_weight(620)


func _ready() -> void:
	custom_minimum_size = Vector2(0.0, 64.0)
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
	var font := get_theme_default_font()
	var enabled := is_enabled()
	_draw_glyph(IconCatalog.good_semantic("technology_points"), Vector2(3.0, 14.0), 12,
		UITokens.CLIMATE.lerp(UITokens.TEXT_MAIN, 0.40))
	draw_string(_label_font, Vector2(21.0, 14.0), "科技值采购",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)
	var value_text := "关闭" if not enabled else "每日 %s" % \
		UITokens.format_compact_number_cn(float(_limit) / CASH_SCALE, 2)
	var value_extent := _label_font.get_string_size(
		value_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL)
	draw_string(_label_font, Vector2(size.x - value_extent.x - 1.0, 14.0), value_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL,
		UITokens.BRASS_HIGHLIGHT if enabled else UITokens.TEXT_FAINT)
	var track := Rect2(GRABBER_RADIUS, TRACK_TOP, maxf(1.0, size.x - GRABBER_RADIUS * 2.0),
		TRACK_HEIGHT)
	draw_rect(track, Color(0.024, 0.021, 0.018, 0.94), true)
	draw_rect(track, Color(UITokens.PANEL_BORDER_SOFT.r, UITokens.PANEL_BORDER_SOFT.g,
		UITokens.PANEL_BORDER_SOFT.b, 0.80), false, 1.0)
	for tick in TICKS:
		var tick_x := track.position.x + track.size.x * float(tick)
		draw_line(Vector2(tick_x, track.position.y - 3.0),
			Vector2(tick_x, track.position.y - 1.0),
			Color(UITokens.PANEL_BORDER.r, UITokens.PANEL_BORDER.g,
				UITokens.PANEL_BORDER.b, 0.66), 1.0, true)
	if enabled:
		draw_rect(Rect2(track.position, Vector2(_grabber_x() - track.position.x,
			track.size.y)), UITokens.ACCENT.lerp(UITokens.BRASS_HIGHLIGHT, 0.34), true)
	var grabber := Vector2(_grabber_x(), TRACK_TOP + TRACK_HEIGHT * 0.5)
	var radius := GRABBER_RADIUS + (1.4 if _dragging or _hovered else 0.0)
	draw_circle(grabber + Vector2(0.0, 1.0), radius + 1.2, Color(0.0, 0.0, 0.0, 0.46))
	draw_circle(grabber, radius, UITokens.WALNUT_SOFT if not enabled \
		else UITokens.BRASS_HIGHLIGHT.lerp(UITokens.WALNUT, 0.28))
	draw_arc(grabber, radius - 1.0, 0.0, TAU, 18,
		Color(1.0, 0.93, 0.72, 0.66 if _dragging or _hovered else 0.34), 1.1, true)
	draw_string(font, Vector2(1.0, 58.0), _preview_text(),
		HORIZONTAL_ALIGNMENT_LEFT, size.x - 2.0, UITokens.FONT_SMALL, UITokens.TEXT_FAINT)


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
	var glyph := IconCatalog.glyph_for_key(semantic)
	if not glyph.is_empty():
		draw_string(IconCatalog.FONT_AWESOME, baseline, glyph,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size, colour)
