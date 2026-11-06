extends Control
class_name BudgetShareSlider

## 通用预算份额滑条：拖动即预览、松手才提交、最左端归零关闭。
##
## 组件只负责几何、交互、四态材质与绘制骨架；份额折成多少钱、走哪条命令，
## 由宿主每次刷新推入或由子类覆写读数钩子。这样国家购买、科技、时代收购、
## 开拓与军事各通道共用同一套手感，而金额口径留在各自的页面里。
##
## 四态：常态纸白滑块；悬停描边提亮一圈；按下加粗并加一圈墨色虚环；
## 禁用整体降透明度，但文字保持可读以配合 tooltip 解释原因。
## 键盘与手柄用 ui_left / ui_right 逐档调整，一次按键即一次完整提交。

signal share_previewed(bp: int)
signal share_committed(bp: int)
const TouchUI = preload("res://scripts/ui/touch_ui.gd")

const TRACK_HEIGHT := 8.0
const MAX_TRACK_WIDTH := 820.0
const GRABBER_RADIUS := 6.5
const HIT_BAND := 12.0
const TICKS := [0.0, 0.25, 0.5, 0.75, 1.0]
const LINE_FONT := 14
const VALUE_FONT := 17

var _max_bp := 1000
var _step_bp := 10
## 可拖上限：-1 表示用满量程，>=0 时由宿主按外部约束收窄。
var _ceiling_bp := -1
var _bp := 0
var _interactive := true
var _dragging := false
var _hovered := false
var _condensed := false
var _title := ""
var _icon: StringName = &""
var _hint_text := ""
var _value_text := ""
var _note := ""
var _warn := false
var _height_full := 118.0
var _height_condensed := 58.0
var _track_top_full := 61.0
var _track_top_condensed := 32.0
var _track_style := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(0.0, _height_condensed)


func _ready() -> void:
	_track_style.set_corner_radius_all(int(TRACK_HEIGHT * 0.5))
	_track_style.anti_aliasing = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(0.0, _height_condensed if _condensed else _height_full)


## 档位：max_bp 为满量程基点（1000 = 10%，10000 = 100%），step_bp 为一档。
## 两档都取整数档，提交值不会出现 0.137% 这类伪精度。
func configure(title: String, icon_key: StringName, max_bp: int, step_bp: int,
		note := "") -> void:
	_title = title
	_icon = icon_key
	_step_bp = maxi(1, int(step_bp))
	_max_bp = maxi(_step_bp, int(max_bp))
	_note = note
	_bp = clampi(_bp, 0, effective_max_bp())
	queue_redraw()


## 子类用来改版式：整块高度与轨道基线，随紧凑档各有一套。
func configure_layout(height_full: float, track_top_full: float,
		height_condensed: float, track_top_condensed: float) -> void:
	_height_full = maxf(24.0, height_full)
	_track_top_full = maxf(12.0, track_top_full)
	_height_condensed = maxf(24.0, height_condensed)
	_track_top_condensed = maxf(10.0, track_top_condensed)
	_apply_min_size()
	queue_redraw()


func set_condensed(condensed: bool) -> void:
	if _condensed == condensed:
		return
	_condensed = condensed
	_apply_min_size()
	queue_redraw()


## bp：当前份额；interactive=false 为禁用态（数据缺席），仍保留读数与 tooltip。
## hint_text 画在轨道左上方，value_text 右对齐到轨道末端。
func set_share_state(bp: int, interactive: bool, hint_text: String, value_text: String,
		warn := false) -> void:
	_interactive = interactive
	_hint_text = hint_text
	_value_text = value_text
	_warn = warn
	if not _dragging:
		_bp = clampi(int(bp), 0, effective_max_bp())
	if not interactive and _hovered:
		_hovered = false
	_on_share_changed(false)
	queue_redraw()


func share_bp() -> int:
	return _bp


func max_bp() -> int:
	return _max_bp


## 当前实际可拖上限：受满量程与外部约束中较小的那个限制。
func effective_max_bp() -> int:
	if _ceiling_bp < 0:
		return _max_bp
	return mini(_max_bp, _ceiling_bp)


func ceiling_bp() -> int:
	return _ceiling_bp


## 外部约束（例如"三项份额之和 <= 100%"）收窄可拖范围。
## 传 -1 解除约束；传小于当前份额的值时，份额会被一并压到上限。
func set_ceiling_bp(ceiling_bp: int) -> void:
	_ceiling_bp = -1 if ceiling_bp < 0 else clampi(ceiling_bp, 0, _max_bp)
	var limit := effective_max_bp()
	if _bp > limit:
		_bp = limit
	queue_redraw()


func step_bp() -> int:
	return _step_bp


func is_enabled() -> bool:
	return _bp > 0


func is_interactive() -> bool:
	return _interactive


func is_dragging() -> bool:
	return _dragging


func set_warn(warn: bool) -> void:
	if _warn == warn:
		return
	_warn = warn
	queue_redraw()


func _apply_min_size() -> void:
	custom_minimum_size = Vector2(0.0, _height_condensed if _condensed else _height_full)


func _track_top() -> float:
	return _track_top_condensed if _condensed else _track_top_full


func _hit_band() -> float:
	if not TouchUI.is_touch():
		return HIT_BAND
	return maxf(HIT_BAND, TouchUI.dense_units() * 0.5)


func _track_rect() -> Rect2:
	return Rect2(GRABBER_RADIUS, _track_top(),
		maxf(1.0, minf(size.x, MAX_TRACK_WIDTH) - GRABBER_RADIUS * 2.0), TRACK_HEIGHT)


func _grabber_x() -> float:
	var track := _track_rect()
	var limit := effective_max_bp()
	if limit <= 0:
		return track.position.x
	return track.position.x + track.size.x * float(mini(_bp, limit)) / float(limit)


func _gui_input(event: InputEvent) -> void:
	if not _interactive:
		return
	if event.is_action_pressed("ui_left"):
		_nudge(-1)
		accept_event()
		return
	if event.is_action_pressed("ui_right"):
		_nudge(1)
		accept_event()
		return
	var hit_band := _hit_band()
	var mid_y := _track_top() + TRACK_HEIGHT * 0.5
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if absf(button.position.y - mid_y) > hit_band \
					or button.position.x > _track_rect().end.x + GRABBER_RADIUS + hit_band:
				return
			if is_inside_tree():
				grab_focus()
			_dragging = true
			_hovered = true
			_apply_position(button.position.x)
			accept_event()
			return
		if _dragging:
			_dragging = false
			if TouchUI.is_touch():
				_hovered = false
			_on_share_changed(false)
			share_committed.emit(_bp)
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
		var inside := absf(motion.position.y - mid_y) <= hit_band \
			and motion.position.x <= _track_rect().end.x + GRABBER_RADIUS + hit_band
		if inside != _hovered:
			_hovered = inside
			queue_redraw()


func _nudge(direction: int) -> void:
	var next_bp := clampi(_bp + _step_bp * direction, 0, effective_max_bp())
	if next_bp == _bp:
		return
	_bp = next_bp
	_on_share_changed(true)
	queue_redraw()
	share_previewed.emit(_bp)
	# 键盘/手柄没有「松手」这一步：一次按键就是一次完整手势，直接提交。
	share_committed.emit(_bp)


func _apply_position(x: float) -> void:
	var track := _track_rect()
	var limit := effective_max_bp()
	var ratio := clampf((x - track.position.x) / track.size.x, 0.0, 1.0)
	var stepped := int(round(ratio * float(limit) / float(_step_bp))) * _step_bp
	var next_bp := clampi(stepped, 0, limit)
	if next_bp == _bp:
		return
	_bp = next_bp
	_on_share_changed(true)
	queue_redraw()
	share_previewed.emit(_bp)


## 份额变化的钩子：子类在这里按新份额重算读数文本（拖动中要实时跟手）。
func _on_share_changed(_dragging: bool) -> void:
	pass


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			if _hovered and not _dragging:
				_hovered = false
				queue_redraw()
		NOTIFICATION_FOCUS_ENTER, NOTIFICATION_FOCUS_EXIT:
			queue_redraw()


func _draw() -> void:
	if size.x < 2.0 or size.y < 2.0:
		return
	var alpha := 1.0 if _interactive else 0.45
	var track := _track_rect()
	var right := track.end.x + GRABBER_RADIUS
	var top := _track_top()
	var on := _bp > 0

	_draw_head(alpha, top)
	_draw_readouts(alpha, top, right)
	_draw_track(track, top, on, alpha)
	_draw_grabber(on, alpha)
	_draw_foot(alpha, top, right)
	if has_focus() and _interactive:
		_draw_focus_outline()


func _draw_head(alpha: float, _track_top_value: float) -> void:
	if _condensed:
		return
	if _icon != &"":
		IconCatalog.draw_icon(self, _icon, Rect2(Vector2(2.0, 6.0), Vector2.ONE * 18.0), alpha)
	draw_string(UITokens.dossier_font("sans_strong"), Vector2(26.0, 21.0), _title,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(UITokens.DOSSIER_INK, alpha))


func _draw_readouts(alpha: float, top: float, right: float) -> void:
	var baseline := top - 9.0
	if not _hint_text.is_empty():
		draw_string(UITokens.dossier_font("sans"), Vector2(1.0, baseline), _hint_text,
			HORIZONTAL_ALIGNMENT_LEFT, maxf(48.0, right * 0.48), LINE_FONT,
			Color(UITokens.DOSSIER_INK_MUTED, alpha))
	if _value_text.is_empty():
		return
	var numeral := UITokens.dossier_font("numeral")
	var value_width := numeral.get_string_size(_value_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		VALUE_FONT).x
	var value_colour := UITokens.DOSSIER_OXBLOOD if _bp > 0 else UITokens.DOSSIER_INK_MUTED
	if _warn:
		value_colour = UITokens.RISK
	draw_string(numeral, Vector2(maxf(1.0, right - value_width - 1.0), baseline), _value_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, VALUE_FONT, Color(value_colour, alpha))


func _draw_track(track: Rect2, top: float, on: bool, alpha: float) -> void:
	# 手绘感：圆角纸槽之外再压一条 1 像素抖线，避免纯几何的工业味。
	_track_style.bg_color = Color(UITokens.DOSSIER_TRACK, alpha)
	draw_style_box(_track_style, track)
	draw_polyline(_sketch_line(track.position.x, track.end.x, top + TRACK_HEIGHT - 1.5),
		Color(UITokens.DOSSIER_INK, 0.10 * alpha), 1.0, true)
	for tick in TICKS:
		var tick_x := track.position.x + track.size.x * float(tick)
		draw_line(Vector2(tick_x, track.end.y + 2.0), Vector2(tick_x, track.end.y + 5.0),
			Color(UITokens.DOSSIER_RULE, alpha), 1.0)
	if not on:
		return
	var fill := UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_OXBLOOD, 0.35)
	if _warn:
		fill = UITokens.RISK.lerp(UITokens.DOSSIER_OXBLOOD, 0.3)
	_track_style.bg_color = Color(fill, alpha)
	draw_style_box(_track_style, Rect2(track.position,
		Vector2(maxf(TRACK_HEIGHT, _grabber_x() - track.position.x), track.size.y)))


func _draw_grabber(on: bool, alpha: float) -> void:
	var centre := Vector2(_grabber_x(), _track_top() + TRACK_HEIGHT * 0.5)
	var radius := GRABBER_RADIUS
	if _dragging:
		radius += 1.6
	elif _hovered:
		radius += 1.0
	draw_circle(centre, radius + 1.2, Color(UITokens.DOSSIER_INK, 0.32 * alpha))
	if _dragging:
		draw_arc(centre, radius + 2.6, 0.0, TAU, 24, Color(UITokens.DOSSIER_INK, 0.45 * alpha),
			1.5, true)
	draw_circle(centre, radius, Color(UITokens.DOSSIER_PAPER, alpha))
	var core := UITokens.DOSSIER_OXBLOOD if on else UITokens.DOSSIER_UMBER
	if not _interactive:
		core = UITokens.DOSSIER_INK_MUTED
	elif _dragging or _hovered:
		core = UITokens.DOSSIER_OXBLOOD if on else UITokens.DOSSIER_BRASS
	draw_circle(centre, maxf(1.5, radius - 2.5), Color(core, alpha))


func _draw_foot(alpha: float, top: float, right: float) -> void:
	if _condensed or _note.is_empty():
		return
	draw_string(UITokens.dossier_font("sans"), Vector2(1.0, top + TRACK_HEIGHT + 26.0), _note,
		HORIZONTAL_ALIGNMENT_LEFT, maxf(40.0, right), 13, Color(UITokens.DOSSIER_INK_MUTED, alpha))


func _draw_focus_outline() -> void:
	var rect := Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0))
	if rect.size.x <= 4.0 or rect.size.y <= 4.0:
		return
	var colour := Color(UITokens.DOSSIER_BRASS, 0.75)
	var step := 5.0
	var x := rect.position.x
	while x < rect.end.x:
		var segment := minf(step, rect.end.x - x)
		draw_line(Vector2(x, rect.position.y), Vector2(x + segment, rect.position.y), colour, 1.0)
		draw_line(Vector2(x, rect.end.y), Vector2(x + segment, rect.end.y), colour, 1.0)
		x += step * 2.0
	var y := rect.position.y
	while y < rect.end.y:
		var segment := minf(step, rect.end.y - y)
		draw_line(Vector2(rect.position.x, y), Vector2(rect.position.x, y + segment), colour, 1.0)
		draw_line(Vector2(rect.end.x, y), Vector2(rect.end.x, y + segment), colour, 1.0)
		y += step * 2.0


## 铅笔抖线：固定种子，同一宽度每次都画同一条，快进重绘时不会抖成噪点。
func _sketch_line(from_x: float, to_x: float, y: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var steps := maxi(4, int((to_x - from_x) / 28.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5C21 + steps
	for index in range(steps + 1):
		var t := float(index) / float(steps)
		points.append(Vector2(lerpf(from_x, to_x, t), y + rng.randf_range(-0.7, 0.7)))
	return points
