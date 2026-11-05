extends Control
class_name EraAdvancementPanel

## 纸徽速览：左栏国家概况，右栏时代晋升；固定高度自绘，无页签、无滚动。
## 超长文字截断加「…」，全文进分区提示（region_tooltip_canvas.gd）。

signal close_requested()
signal command_requested(command: StringName)
signal treasury_requested()
signal reward_requested()

const VM = preload("res://scripts/ui/era_indicator_view_model.gd")
const MAX_WIDTH := 920.0
const MIN_WIDTH := 760.0
const PAD := 34.0
const GUTTER := 28.0
const EDGE := 12.0
# 纸徽全展开时纸笺挂在徽记下方；纵向放不下时纸徽半露、纸笺上移。
const TOP_OPEN := UITokens.ERA_BADGE_OPEN_Y + UITokens.ERA_BADGE_SIZE + UITokens.ERA_POPUP_GAP
const TOP_COMPACT := UITokens.ERA_BADGE_REST_Y + UITokens.ERA_BADGE_SIZE + UITokens.ERA_POPUP_GAP
const MAX_ALERT_CHIPS := 2
const MAX_COST_CHIPS := 4
const SIZE_TITLE := 22
const SIZE_BODY := 14
const SIZE_MINOR := 13

# 行位：纸笺本地坐标，*_Y 为文字基线，*_TOP 为块上沿。纸笺高度由加成行数决定（_rows）。
const KICKER_Y := 36.0
const TITLE_Y := 62.0
const METRIC_TOP := 82.0
const METRIC_ROW := 46.0
const ALERT_H := 28.0
const REWARD_H := 36.0
const BAND_CENTER := 114.0
const OLD_EMBLEM := 64.0
const NEW_EMBLEM := 80.0
const RING_RADIUS := 47.0
const COND_HEAD_Y := 176.0
const COND_TOP := 186.0
const COND_H := 32.0
const COND_GAP := 6.0
const COST_HEAD_Y := 276.0
const COST_TOP := 286.0
const COST_H := 38.0
# 零预算提示独占一行，夹在物资小签与「晋升后获得」之间；有预算时这一行不存在。
const BUDGET_TOP := 330.0
const BUDGET_H := 22.0
const BUDGET_GAP := 16.0
# 右栏内容的最小下沿：加成条数很少时纸笺不塌缩。
const CONTENT_FLOOR := 398.0
const BUFF_HEAD_Y := 340.0
const BUFF_LINE := 19.0
const BUFF_MAX_ROWS := 5
# 操作行：笺线分隔，按钮与纸笺撕边之间留 BOTTOM_CLEAR。
const RULE_GAP := 14.0
const ACTION_GAP := 10.0
const ACTION_H := 34.0
const BOTTOM_CLEAR := 22.0
const ACTION_W := 132.0
const ACTION_TEXT_PAD := 44.0
const HINT_GAP := 20.0
# 纸笺底下的柔光：同形圆角矩形逐层内收、透明度递增，近似模糊。
const HALO_LAYERS := 9
const HALO_DROP := 3.0
const HALO_INSET := 2.0
const HALO_BOTTOM := 8.0
const HALO_ALPHA := 0.16
const HALO_TINT := Color(0.30, 0.22, 0.14)

const METRICS := [
	["gdp", "年度 GDP", &"hud.country.economy", true],
	["per_capita_gdp", "人均 GDP", &"hud.country.economy", true],
	["cpi", "CPI", &"metric.goods", false],
	["ppi", "PPI", &"economy.building.factory", false],
	["territory", "地块", &"country.world", false],
	["satisfaction", "人民满意度", &"population.heart", false],
	["living_standard", "生活水平", &"population.living.comfortable", false],
]

@onready var _sheet: Control = %Sheet
@onready var _canvas: Control = %Canvas
@onready var _close: Button = %Close
@onready var _reward_link: Button = %RewardLink
@onready var _treasury_link: Button = %TreasuryLink
@onready var _action: Button = %Action

var _vm := VM.new()
var _model: Dictionary = {}
var _overview: Dictionary = {}
var _textures: Dictionary = {}
var _pending := false
var _pending_status := ""
var _error := ""
var _closing := false
var _opening: Tween
var _shown_progress := 0.0
var _progress_tween: Tween
var _badge_expanded := true
var _fit_scale := 1.0
var _chip_style := StyleBoxFlat.new()
var _drawn := PackedStringArray()
var _rows: Dictionary = {}


func _ready() -> void:
	_close.pressed.connect(func() -> void: close_requested.emit())
	_action.pressed.connect(_on_action_pressed)
	_treasury_link.pressed.connect(func() -> void: treasury_requested.emit())
	_reward_link.pressed.connect(func() -> void: reward_requested.emit())
	_canvas.draw.connect(_draw_canvas)
	_sheet.draw.connect(_draw_halo)
	_chip_style.set_corner_radius_all(4)
	_chip_style.set_border_width_all(1)
	_chip_style.anti_aliasing = true
	_treasury_link.visible = false
	_treasury_link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_treasury_link.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_treasury_link.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	_treasury_link.add_theme_color_override("font_hover_color", UITokens.DOSSIER_BRASS.darkened(0.1))
	_treasury_link.add_theme_color_override("font_pressed_color", UITokens.DOSSIER_OXBLOOD.darkened(0.2))
	_treasury_link.add_theme_color_override("font_focus_color", UITokens.DOSSIER_OXBLOOD)
	_treasury_link.mouse_entered.connect(_canvas.queue_redraw)
	_treasury_link.mouse_exited.connect(_canvas.queue_redraw)
	_treasury_link.tooltip_text = "国家购买预算份额在国库面板设置"
	_reward_link.tooltip_text = "打开时代奖励三选一"
	_style_action_button()
	resized.connect(_layout)
	get_viewport().size_changed.connect(_layout)
	_model = _vm.present_advancement({})


func open(snapshot: Dictionary, overview: Dictionary = {}) -> void:
	if not overview.is_empty():
		_overview = overview
	set_snapshot(snapshot)
	_show()


func is_open() -> bool:
	return visible and not _closing


func set_snapshot(snapshot: Dictionary) -> void:
	var presented := _vm.present_advancement(snapshot)
	if _pending and String(presented.get("status", "")) != _pending_status:
		_pending = false
	_model = presented
	_apply_model()


func set_overview(overview: Dictionary) -> void:
	_overview = overview
	if is_node_ready():
		_canvas.queue_redraw()


func model() -> Dictionary:
	return _model


func overview_model() -> Dictionary:
	return _overview


func wants_expanded_badge() -> bool:
	return _badge_expanded


func sheet_rect() -> Rect2:
	return _sheet.get_global_rect()


func fit_scale() -> float:
	return _fit_scale


## 上一次绘制的全部文字（含截断后的形态），供测试核对重复与漏项。
func drawn_texts() -> PackedStringArray:
	return _drawn


func show_command_result(result: Dictionary) -> void:
	_pending = false
	_error = "" if bool(result.get("ok", false)) else String(result.get("message",
		result.get("code", "指令未被接受")))
	_apply_model()


func set_reward_available(available: bool) -> void:
	if is_node_ready():
		_reward_link.visible = available
		if visible:
			_layout()
		_canvas.queue_redraw()


func close(immediate: bool = false) -> void:
	if not visible:
		return
	_pending = false
	_error = ""
	if immediate or UIAnimation.reduced_motion():
		if _opening != null and _opening.is_valid():
			_opening.kill()
		visible = false
		_closing = false
		return
	if _closing:
		return
	_closing = true
	if _opening != null and _opening.is_valid():
		_opening.kill()
	_opening = create_tween()
	_opening.tween_property(_sheet, "modulate:a", 0.0, 0.10)
	_opening.tween_callback(func() -> void:
		visible = false
		_closing = false)


func action_button() -> Button:
	return _action


## 按钮左侧只写增量：指令错误优先，其次是还缺的条件。
func action_hint() -> String:
	if not _error.is_empty():
		return _error
	return String(_model.get("delta_hint", ""))


func _apply_model() -> void:
	if not is_node_ready():
		return
	var action: Dictionary = _model.get("action", {})
	_action.visible = bool(action.get("visible", false))
	_action.text = "提交中…" if _pending else String(action.get("text", ""))
	_action.disabled = _pending or bool(action.get("disabled", true))
	_action.tooltip_text = String(action.get("tooltip", ""))
	_action.set_meta(&"command", action.get("command", &""))
	_treasury_link.visible = _needs_budget_link()
	if visible:
		_layout()
	else:
		_rows = _compute_rows()
		_place_buttons(_sheet.size.x)
	_tween_progress(float(_model.get("progress", 0.0)))
	_canvas.queue_redraw()


func _needs_budget_link() -> bool:
	var status := String(_model.get("status", ""))
	if not bool(_model.get("ok", false)) or status == "max":
		return false
	return not bool(_model.get("budget_enabled", false)) or float(_model.get("era_daily", 0.0)) <= 0.0


func _on_action_pressed() -> void:
	if _pending or _action.disabled:
		return
	var command := StringName(_action.get_meta(&"command", &""))
	if command == &"":
		return
	_pending = true
	_pending_status = String(_model.get("status", ""))
	_error = ""
	_apply_model()
	command_requested.emit(command)


func _tween_progress(target: float) -> void:
	if _progress_tween != null and _progress_tween.is_valid():
		_progress_tween.kill()
	if not visible or UIAnimation.reduced_motion() or absf(target - _shown_progress) < 0.002:
		_shown_progress = target
		return
	_progress_tween = create_tween()
	_progress_tween.tween_method(func(value: float) -> void:
		_shown_progress = value
		_canvas.queue_redraw(), _shown_progress, target, 0.22)


func _show() -> void:
	var was_open := visible and not _closing
	_closing = false
	visible = true
	_layout()
	if was_open:
		return
	if _opening != null and _opening.is_valid():
		_opening.kill()
	_sheet.modulate.a = 1.0
	if UIAnimation.reduced_motion():
		return
	var rest := _sheet.position
	_sheet.modulate.a = 0.0
	_sheet.position = rest - Vector2(0.0, 10.0)
	_opening = create_tween().set_parallel(true)
	_opening.tween_property(_sheet, "modulate:a", 1.0, 0.12)
	_opening.tween_property(_sheet, "position", rest, 0.20) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _view_size() -> Vector2:
	if size.x > 1.0 and size.y > 1.0:
		return size
	return get_viewport_rect().size


func _layout() -> void:
	if not is_node_ready():
		return
	var view := _view_size()
	var width := clampf(view.x - 32.0, MIN_WIDTH, MAX_WIDTH)
	_rows = _compute_rows()
	var height: float = _rows.height
	var top := TOP_OPEN
	var fit := 1.0
	_badge_expanded = true
	if TOP_OPEN + height + EDGE > view.y:
		_badge_expanded = false
		top = TOP_COMPACT
		fit = (view.y - top - EDGE) / height
	fit = clampf(minf(fit, (view.x - 2.0 * EDGE) / width), 0.35, 1.0)
	_fit_scale = fit
	_sheet.size = Vector2(width, height)
	_sheet.scale = Vector2.ONE * fit
	if _opening == null or not _opening.is_valid():
		_sheet.position = Vector2(roundf((view.x - width * fit) * 0.5), top)
	_place_buttons(width)
	_sheet.queue_redraw()
	_canvas.queue_redraw()


## 由加成条数推出操作行与纸笺高度；左栏把指标行距撑开，使问题与奖励按钮落在操作行上。
func _compute_rows() -> Dictionary:
	var buffs: PackedStringArray = _model.get("buffs", PackedStringArray())
	var status := String(_model.get("status", ""))
	var buff_rows := _buff_rows(buffs.size())
	var buff_head := _buff_head_y()
	var content_end := CONTENT_FLOOR
	if _budget_row():
		content_end = maxf(content_end, BUDGET_TOP + BUDGET_H)
	if buff_rows > 0:
		content_end = maxf(content_end,
			buff_head + 22.0 + float(buff_rows - 1) * BUFF_LINE + 6.0)
	if status == "max" or not bool(_model.get("ok", false)):
		content_end = maxf(content_end, COST_HEAD_Y - 40.0 + 22.0 + float(buff_rows) * BUFF_LINE)
	# 左栏：指标两行一格，问题纸贴紧跟其后，笺线取两栏较高者。
	var metric_h := METRIC_ROW
	var metrics_bottom := METRIC_TOP + 4.0 * metric_h
	var alert_head_y := metrics_bottom + 18.0
	var alert_top := alert_head_y + 12.0
	content_end = maxf(content_end, alert_top + ALERT_H)
	var rule_y := content_end + RULE_GAP
	# 奖励按钮与主操作同一行：主操作贴右，奖励排在它左侧。
	if _reward_link != null and _reward_link.visible:
		content_end = maxf(content_end, metrics_bottom)
	var action_top := rule_y + ACTION_GAP
	var height := action_top + ACTION_H + BOTTOM_CLEAR
	var reward_top := action_top
	return {"rule_y": rule_y, "action_top": action_top, "height": height, "reward_top": reward_top,
		"alert_top": alert_top, "alert_head_y": alert_head_y, "metric_h": metric_h}


func _buff_rows(count: int) -> int:
	if count <= 0:
		return 0
	var columns := 1 if count <= 4 else (2 if count <= 2 * BUFF_MAX_ROWS else 3)
	return int(ceil(float(count) / float(columns)))


## 零预算提示这一行只在该提示可见时存在。
func _budget_row() -> bool:
	return _treasury_link != null and _treasury_link.visible


## 「晋升后获得」标题基线：预算行出现时整体下移，两者不共用基线。
func _buff_head_y() -> float:
	return BUDGET_TOP + BUDGET_H + BUDGET_GAP if _budget_row() else BUFF_HEAD_Y


func sheet_height() -> float:
	return float(_rows.get("height", 0.0))


## 「晋升后获得」标题基线（零预算提示出现时为它让出空间），供回归测试核对不叠字。
func buff_head_y() -> float:
	return _buff_head_y()


## 文字左右界比纸笺矩形再内收 TEXT_INSET，撕边最深处也留 ≥16px。
const TEXT_INSET := 2.0


func _columns(width: float) -> Dictionary:
	var inset := PAD + TEXT_INSET
	var avail := width - 2.0 * inset - GUTTER
	var left_w := floorf(avail * 0.42)
	var right_x := inset + left_w + GUTTER
	return {"lx": inset, "lw": left_w, "rx": right_x, "rw": width - inset - right_x}


func _place_buttons(width: float) -> void:
	if width <= 1.0:
		return
	var cols := _columns(width)
	var lx: float = cols.lx
	var lw: float = cols.lw
	var rx: float = cols.rx
	var rw: float = cols.rw
	if _rows.is_empty():
		_rows = _compute_rows()
	var action_top: float = _rows.action_top
	_close.position = Vector2(rx + rw - 52.0 + 8.0, 16.0)
	_close.size = Vector2(52.0, 28.0)
	# 时代奖励属于时代这条线，跟主操作同一行，左栏只留国家概况。
	var reward_font := _reward_link.get_theme_font("font")
	var reward_w_raw := reward_font.get_string_size(_reward_link.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		_reward_link.get_theme_font_size("font_size")).x + 30.0 if reward_font != null else 150.0
	var link_font := _treasury_link.get_theme_font("font")
	var link_w := link_font.get_string_size(_treasury_link.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		_treasury_link.get_theme_font_size("font_size")).x + 8.0 if link_font != null else rw
	# 预算行独占一格：右对齐在右栏右端，位于物资小签与「晋升后获得」之间。
	_treasury_link.position = Vector2(rx + rw - minf(link_w, rw), BUDGET_TOP)
	_treasury_link.size = Vector2(minf(link_w, rw), BUDGET_H)
	var font := _action.get_theme_font("font")
	var font_size := _action.get_theme_font_size("font_size")
	var text_w := font.get_string_size(_action.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x \
		if font != null else ACTION_W
	var button_w := clampf(text_w + ACTION_TEXT_PAD, ACTION_W, rw)
	_action.position = Vector2(rx + rw - button_w, action_top)
	_action.size = Vector2(button_w, ACTION_H)
	# 奖励按钮跟主操作同一行，贴在它左侧。
	var reward_w := clampf(reward_w_raw, 118.0, rw * 0.5)
	_reward_link.position = Vector2(_action.position.x - 10.0 - reward_w, action_top)
	_reward_link.size = Vector2(reward_w, ACTION_H)


func _style_action_button() -> void:
	var radius := 5
	var normal := StyleBoxFlat.new()
	normal.bg_color = UITokens.DOSSIER_OXBLOOD
	normal.border_color = Color(UITokens.DOSSIER_BRASS, 0.92)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(radius)
	normal.set_content_margin_all(0.0)
	normal.shadow_color = Color(0.24, 0.14, 0.08, 0.30)
	normal.shadow_size = 4
	normal.shadow_offset = Vector2(0, 2)
	normal.anti_aliasing = true
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = UITokens.DOSSIER_OXBLOOD.lightened(0.10)
	hover.border_color = UITokens.DOSSIER_BRASS
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = UITokens.DOSSIER_OXBLOOD.darkened(0.16)
	pressed.shadow_size = 1
	pressed.shadow_offset = Vector2(0, 1)
	var disabled := StyleBoxFlat.new()
	disabled.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	disabled.border_color = Color(UITokens.DOSSIER_BRASS, 0.55)
	disabled.shadow_size = 0
	disabled.set_border_width_all(1)
	disabled.set_corner_radius_all(radius)
	disabled.set_content_margin_all(0.0)
	disabled.anti_aliasing = true
	_action.add_theme_stylebox_override("normal", normal)
	_action.add_theme_stylebox_override("hover", hover)
	_action.add_theme_stylebox_override("pressed", pressed)
	_action.add_theme_stylebox_override("disabled", disabled)
	_action.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_action.add_theme_font_override("font", UITokens.dossier_font("serif"))
	_action.add_theme_font_size_override("font_size", SIZE_BODY + 2)
	_action.add_theme_color_override("font_color", Color(0.98, 0.94, 0.86))
	_action.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.90))
	_action.add_theme_color_override("font_pressed_color", Color(0.95, 0.89, 0.80))
	_action.add_theme_color_override("font_focus_color", Color(0.98, 0.94, 0.86))
	_action.add_theme_color_override("font_disabled_color", UITokens.DOSSIER_INK_MUTED)
	_style_reward_button()


## 「领取时代奖励」是可选动作，不能和晋升按钮抢主角：细铜边、纸面底、墨色字。
func _style_reward_button() -> void:
	var secondary := StyleBoxFlat.new()
	secondary.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	secondary.border_color = Color(UITokens.DOSSIER_BRASS, 0.5)
	secondary.set_border_width_all(1)
	secondary.set_corner_radius_all(4)
	secondary.set_content_margin_all(0.0)
	secondary.anti_aliasing = true
	var hover := secondary.duplicate() as StyleBoxFlat
	hover.bg_color = Color(UITokens.DOSSIER_BRASS, 0.12)
	hover.border_color = UITokens.DOSSIER_BRASS
	for state in ["normal", "pressed"]:
		_reward_link.add_theme_stylebox_override(state, secondary)
	_reward_link.add_theme_stylebox_override("hover", hover)
	_reward_link.add_theme_stylebox_override("disabled", secondary)
	_reward_link.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_reward_link.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	_reward_link.add_theme_color_override("font_hover_color", UITokens.DOSSIER_OXBLOOD)
	_reward_link.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_reward_link.add_theme_font_size_override("font_size", SIZE_MINOR + 1)


func _input(event: InputEvent) -> void:
	if not visible or _closing:
		return
	if event.is_action_pressed("player_cancel") or event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()
	elif (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventScreenTouch and event.pressed):
		# 点纸徽交给纸徽自己开关；其余空白处收起并吞掉，避免误选地图。
		var badge_rect := Rect2(Vector2(get_viewport_rect().size.x * 0.5 - UITokens.ERA_BADGE_SIZE * 0.5, 0),
			Vector2(UITokens.ERA_BADGE_SIZE, UITokens.ERA_BADGE_SIZE + UITokens.ERA_BADGE_OPEN_Y))
		var point: Vector2 = event.position
		if not _sheet.get_global_rect().has_point(point) and not badge_rect.has_point(point):
			close_requested.emit()
			get_viewport().set_input_as_handled()


static func fit_text(font: Font, text: String, font_size: int, max_width: float) -> String:
	if font == null or max_width <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
		return text
	var ellipsis := "…"
	var cut := text.length()
	while cut > 0:
		cut -= 1
		var candidate := text.substr(0, cut).strip_edges() + ellipsis
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
			return candidate
	return ellipsis


## 单行绘制；被截断时自动把全文登记为提示。返回实际绘制宽度。
func _text(pos: Vector2, text: String, font: Font, font_size: int, color: Color,
		max_width: float, align := HORIZONTAL_ALIGNMENT_LEFT, tooltip := "") -> float:
	var shown := fit_text(font, text, font_size, max_width)
	if shown != text and tooltip.is_empty():
		tooltip = text
	_canvas.draw_string(font, pos, shown, align, max_width, font_size, color)
	_drawn.append(shown)
	if not tooltip.is_empty():
		_region(Rect2(pos.x, pos.y - font_size, max_width, font_size * 1.35), tooltip)
	return font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x


func _region(rect: Rect2, text: String) -> void:
	_canvas.call("add_region", rect, text)


func _era_texture(era_id: String) -> Texture2D:
	if not _textures.has(era_id):
		_textures[era_id] = EraIndicator.era_texture(era_id)
	return _textures[era_id]


func _draw_halo() -> void:
	var outer := Rect2(Vector2(HALO_INSET, HALO_DROP),
		Vector2(_sheet.size.x - 2.0 * HALO_INSET, _sheet.size.y - HALO_DROP + HALO_BOTTOM))
	var box := StyleBoxFlat.new()
	box.anti_aliasing = true
	for i in range(HALO_LAYERS):
		var t := float(i) / float(HALO_LAYERS - 1)
		box.bg_color = Color(HALO_TINT, lerpf(0.01, HALO_ALPHA, t) / float(HALO_LAYERS) * 2.0)
		box.set_corner_radius_all(int(16.0 - float(i)))
		_sheet.draw_style_box(box, outer.grow(-float(i)))


func _draw_canvas() -> void:
	_canvas.call("clear_regions")
	_drawn = PackedStringArray()
	var cols := _columns(_sheet.size.x)
	var lx: float = cols.lx
	var lw: float = cols.lw
	var rx: float = cols.rx
	var rw: float = cols.rw
	_draw_overview(lx, lw)
	var rule_x := rx - GUTTER * 0.5
	_canvas.draw_line(Vector2(rule_x, 26.0), Vector2(rule_x, _sheet.size.y - BOTTOM_CLEAR),
		Color(UITokens.DOSSIER_RULE, 0.6), 1.0)
	_draw_advancement(rx, rw)
	if _treasury_link.visible and _treasury_link.is_hovered():
		var r := _treasury_link.get_rect()
		var underline_y := r.end.y - 3.0
		_canvas.draw_line(Vector2(r.position.x + 4.0, underline_y), Vector2(r.end.x - 4.0, underline_y),
			Color(UITokens.DOSSIER_BRASS, 0.8), 1.0)


func _draw_overview(x: float, w: float) -> void:
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var numeral := UITokens.dossier_font("numeral")
	var display := UITokens.dossier_font("serif")
	var o := _overview
	_text(Vector2(x, KICKER_Y), "国家概况", strong, SIZE_BODY, UITokens.DOSSIER_OXBLOOD, w - 60.0)
	var country_name := String(o.get("country_name", ""))
	var name_size := SIZE_TITLE
	# 国名同样先缩字号，缩到 16 仍放不下才省略。
	while name_size > 16 and display.get_string_size(country_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			name_size).x > w:
		name_size -= 1
	_text(Vector2(x, TITLE_Y), country_name, display, name_size, UITokens.DOSSIER_INK, w)
	var cell_w := floorf((w - 14.0) * 0.5)
	var metric_h: float = _rows.get("metric_h", METRIC_ROW)
	for i in range(METRICS.size()):
		var spec: Array = METRICS[i]
		var cx := x + float(i % 2) * (cell_w + 14.0)
		var cy := METRIC_TOP + float(i / 2) * metric_h
		if i >= 2:
			_canvas.draw_line(Vector2(cx, cy), Vector2(cx + cell_w, cy),
				Color(UITokens.DOSSIER_RULE, 0.4), 1.0)
		var label := String(spec[1])
		var value := String(o.get(String(spec[0]), "—"))
		# 两行一格：名称一行、数值单独一行，比挤在同一行好读，也比旧版 62px 矮。
		var row_top := cy + 4.0
		IconCatalog.draw_icon(_canvas, spec[2], Rect2(cx, row_top + 1.0, 14.0, 14.0))
		_text(Vector2(cx + 20.0, row_top + 13.0), label, sans, SIZE_MINOR,
			UITokens.DOSSIER_INK_MUTED, cell_w - 20.0)
		var value_size := SIZE_BODY + 4
		var vx := cx + 20.0
		if bool(spec[3]) and value != "—":
			vx += MoneyDisplay.draw_on_baseline(_canvas, Vector2(vx, row_top + 36.0), SIZE_BODY + 1, numeral)
		_text(Vector2(vx, row_top + 36.0), value, numeral, value_size, UITokens.DOSSIER_INK,
			cx + cell_w - vx)
		_region(Rect2(cx, cy, cell_w, metric_h), String(o.get("%s_tooltip" % String(spec[0]), label)))
	_draw_alerts(x, w)


func _draw_alerts(x: float, w: float) -> void:
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var alerts: Array = _overview.get("alerts", [])
	if alerts.is_empty():
		return
	var alert_top: float = _rows.get("alert_top", 0.0)
	_text(Vector2(x, _rows.get("alert_head_y", 0.0)), "国家问题", strong, SIZE_BODY, UITokens.DOSSIER_INK,
		w * 0.5)
	var cx := x
	var shown := 0
	for i in range(alerts.size()):
		var alert: Dictionary = alerts[i]
		var label := String(alert.get("label", ""))
		var chip_w := 42.0 + sans.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SIZE_MINOR).x
		var reserve := 44.0 if i < alerts.size() - 1 else 0.0
		if shown >= MAX_ALERT_CHIPS or cx + chip_w > x + w - reserve:
			if shown > 0:
				break
			chip_w = maxf(60.0, x + w - reserve - cx)
		_chip(Rect2(cx, alert_top, chip_w, ALERT_H), StringName(alert.get("icon", &"situation.food_shortage")),
			label, true, String(alert.get("tooltip", label)))
		cx += chip_w + 6.0
		shown += 1
	if shown < alerts.size():
		var lines := PackedStringArray()
		for i in range(shown, alerts.size()):
			lines.append(String((alerts[i] as Dictionary).get("tooltip", "")))
		_chip(Rect2(cx, alert_top, 38.0, ALERT_H), &"", "+%d" % (alerts.size() - shown), true,
			"\n\n".join(lines))


func _chip(rect: Rect2, icon: StringName, label: String, negative: bool, tooltip: String) -> void:
	var sans := UITokens.dossier_font("sans")
	_chip_style.bg_color = UITokens.DOSSIER_BADGE_NEGATIVE if negative else UITokens.DOSSIER_BADGE_POSITIVE
	_chip_style.border_color = Color(UITokens.DOSSIER_OXBLOOD if negative else UITokens.DOSSIER_VERDIGRIS, 0.45)
	_canvas.draw_style_box(_chip_style, rect)
	var tx := rect.position.x + 8.0
	if icon != &"":
		IconCatalog.draw_icon(_canvas, icon, Rect2(tx, rect.position.y + 5.0, 18.0, 18.0))
		tx += 24.0
	var colour := UITokens.DOSSIER_OXBLOOD if negative else UITokens.DOSSIER_VERDIGRIS
	_text(Vector2(tx, rect.position.y + 19.0), label, sans, SIZE_MINOR, colour, rect.end.x - tx - 6.0)
	_region(rect, tooltip)


func _draw_advancement(x: float, w: float) -> void:
	var m := _model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var display := UITokens.dossier_font("serif")
	_text(Vector2(x, KICKER_Y), "时代晋升", strong, SIZE_BODY, UITokens.DOSSIER_OXBLOOD, w - 70.0)
	if not bool(m.get("ok", false)):
		_text(Vector2(x, TITLE_Y), "数据暂不可用", display, SIZE_TITLE, UITokens.DOSSIER_INK_MUTED, w)
		return
	var status := String(m.get("status", ""))
	var current: Dictionary = m.get("current", {})
	var next: Dictionary = m.get("next", {})
	var chip_w := _draw_status_chip(x + w, status)
	var era_line := String(current.get("name", "")) if next.is_empty() \
		else "%s → %s" % [String(current.get("name", "")), String(next.get("name", ""))]
	_text(Vector2(x, TITLE_Y), era_line, display, SIZE_TITLE, UITokens.DOSSIER_INK, w - chip_w - 12.0)
	if status == "max":
		_draw_max(x, w)
		return
	_draw_band(x, w, status)
	_draw_conditions(x, w)
	_draw_costs(x, w)
	_draw_buffs(x, w, _buff_head_y(), "晋升后获得")
	var rule_y: float = _rows.rule_y
	_canvas.draw_line(Vector2(x, rule_y), Vector2(x + w, rule_y), Color(UITokens.DOSSIER_RULE, 0.75), 1.0)
	var hint := action_hint()
	if not hint.is_empty():
		var hint_right := _action.position.x - HINT_GAP if _action.visible else x + w
		if _reward_link != null and _reward_link.visible:
			hint_right = minf(hint_right, _reward_link.position.x - 10.0)
		# 文字视觉中心（基线上方 ascent/2）对齐按钮中心。
		var centre: float = float(_rows.action_top) + ACTION_H * 0.5
		var baseline := centre + sans.get_ascent(SIZE_MINOR) * 0.5 - 1.0
		_text(Vector2(x, baseline), hint, sans, SIZE_MINOR,
			UITokens.DOSSIER_OXBLOOD if not _error.is_empty() else UITokens.DOSSIER_INK_MUTED,
			maxf(0.0, hint_right - x), HORIZONTAL_ALIGNMENT_LEFT, hint)


func _status_colour(status: String) -> Color:
	match status:
		"ready", "completing", "max": return UITokens.DOSSIER_VERDIGRIS
		"locked": return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_INK_SOFT


## 状态签右对齐在时代行基线上，返回其宽度。
func _draw_status_chip(right: float, status: String) -> float:
	var sans := UITokens.dossier_font("sans_strong")
	var text := String(_model.get("status_chip", ""))
	if text.is_empty():
		return 0.0
	var colour := _status_colour(status)
	var text_w := sans.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SIZE_MINOR).x
	var rect := Rect2(right - text_w - 18.0, TITLE_Y - 18.0, text_w + 18.0, 24.0)
	_chip_style.bg_color = Color(colour, 0.08)
	_chip_style.border_color = Color(colour, 0.55)
	_canvas.draw_style_box(_chip_style, rect)
	_canvas.draw_string(sans, Vector2(rect.position.x + 9.0, TITLE_Y - 1.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, SIZE_MINOR, colour)
	_drawn.append(text)
	return rect.size.x


func _draw_band(x: float, w: float, status: String) -> void:
	var current: Dictionary = _model.get("current", {})
	var next: Dictionary = _model.get("next", {})
	var progress := clampf(_shown_progress, 0.0, 1.0)
	var filling := status in ["purchasing", "paused", "completing"]
	var ring_ink := Color(UITokens.DOSSIER_INK_SOFT, 0.5)
	var accent := UITokens.DOSSIER_BRASS if status != "paused" else UITokens.DOSSIER_UMBER
	# 一组居中的「旧徽 → 双刻箭 → 主徽」。主徽是视觉重心，进度用它的手绘笔锋弧表达；
	# 中间不再画横贯整行的进度轨。
	var old_side := OLD_EMBLEM
	var new_side := NEW_EMBLEM
	var chevron_w := 22.0
	var gap := 14.0
	var group := old_side + gap + chevron_w + gap + new_side
	var left := x + maxf(0.0, (w - group) * 0.5)
	var old_center := Vector2(left + old_side * 0.5, BAND_CENTER)
	var new_center := Vector2(left + group - new_side * 0.5, BAND_CENTER)
	_canvas.draw_arc(old_center, old_side * 0.5 + 4.0, 0.0, TAU, 64, ring_ink, 1.5, true)
	var old_icon := _era_texture(String(current.get("id", "")))
	if old_icon != null:
		_canvas.draw_texture_rect(old_icon, Rect2(old_center - Vector2.ONE * old_side * 0.5,
			Vector2.ONE * old_side), false, Color(1, 1, 1, 0.86))
	# 双刻箭：两枚手刻的三角刻痕，代替一条长直线。
	var chev_x := left + old_side + gap
	for i in range(2):
		var cx := chev_x + float(i) * 9.0
		var ink := Color(UITokens.DOSSIER_INK_SOFT, 0.5 - float(i) * 0.14)
		_canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(cx, BAND_CENTER - 7.0),
			Vector2(cx + 8.0, BAND_CENTER),
			Vector2(cx, BAND_CENTER + 7.0),
			Vector2(cx + 3.2, BAND_CENTER)]), ink)
	# 主徽底环：淡墨细圈，让笔锋弧有落笔的位置。
	_canvas.draw_arc(new_center, RING_RADIUS, 0.0, TAU, 96, Color(UITokens.DOSSIER_INK_SOFT, 0.16), 4.0, true)
	if filling and progress > 0.0:
		_draw_brush_ring(new_center, RING_RADIUS, progress, accent)
	var new_icon := _era_texture(String(next.get("id", "")))
	if new_icon != null:
		var tint := Color.WHITE if status != "locked" else Color(0.82, 0.78, 0.72, 0.9)
		_canvas.draw_texture_rect(new_icon, Rect2(new_center - Vector2.ONE * new_side * 0.5,
			Vector2.ONE * new_side), false, tint)


## 手绘笔锋弧：由粗到细分段铺，末端收成尖锋，读起来像蘸墨画的一圈，而不是仪表刻度。
func _draw_brush_ring(centre: Vector2, radius: float, ratio: float, colour: Color) -> void:
	var steps := maxi(24, int(96.0 * ratio))
	var start := -PI * 0.5
	var sweep := TAU * clampf(ratio, 0.0, 1.0)
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var width := lerpf(5.2, 2.2, t0)
		var alpha := lerpf(0.95, 0.55, t0)
		_canvas.draw_arc(centre, radius, start + sweep * t0, start + sweep * t1, 6,
			Color(colour, alpha), width, true)
	# 起笔一点、收笔尖锋：避免圆弧两端是生硬的平口。
	var head := start
	_canvas.draw_circle(centre + Vector2(cos(head), sin(head)) * radius, 3.4,
		Color(colour, 0.95), true, -1.0, true)
	var tail := start + sweep
	var tip := centre + Vector2(cos(tail), sin(tail)) * radius
	var tangent := Vector2(-sin(tail), cos(tail))
	var normal := Vector2(cos(tail), sin(tail))
	_canvas.draw_colored_polygon(PackedVector2Array([
		tip + normal * 2.4,
		tip - normal * 2.4,
		tip + tangent * 5.0]), Color(colour, 0.75))


func _draw_conditions(x: float, w: float) -> void:
	var m := _model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var numeral := UITokens.dossier_font("numeral")
	_text(Vector2(x, COND_HEAD_Y), "前提条件 · 任选其二", strong, SIZE_BODY, UITokens.DOSSIER_INK, w)
	var rows: Array = m.get("conditions", [])
	var tile_w := floorf((w - COND_GAP) * 0.5)
	for i in range(mini(rows.size(), 4)):
		var row: Dictionary = rows[i]
		var met := bool(row.get("met", false))
		var rect := Rect2(x + float(i % 2) * (tile_w + COND_GAP),
			COND_TOP + float(i / 2) * (COND_H + COND_GAP), tile_w, COND_H)
		_chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		_chip_style.border_color = Color(UITokens.DOSSIER_VERDIGRIS, 0.5) if met \
			else Color(UITokens.DOSSIER_RULE, 0.5)
		_canvas.draw_style_box(_chip_style, rect)
		var baseline := rect.position.y + 22.0
		IconCatalog.draw_icon(_canvas, &"control.checkbox_checked" if met else &"control.checkbox_unchecked",
			Rect2(rect.position.x + 7.0, rect.position.y + 9.0, 16.0, 16.0), 1.0 if met else 0.7)
		# 条件行不再挂装饰图标：勾选框 + 名称 + 数值已经够读，多一个图标只会把名称挤成省略号。
		var value := String(row.get("value_text", row.get("text", "")))
		var value_w := numeral.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SIZE_MINOR).x
		var colour := UITokens.DOSSIER_VERDIGRIS if met else UITokens.DOSSIER_INK
		var label := String(row.get("label", ""))
		_text(Vector2(rect.position.x + 30.0, baseline), label, strong if met else sans, SIZE_MINOR, colour,
			rect.size.x - 30.0 - value_w - 12.0)
		_text(Vector2(rect.end.x - value_w - 8.0, baseline), value, numeral, SIZE_MINOR, colour, value_w + 1.0)
		var tip := String(row.get("tooltip", ""))
		_region(rect, "%s：%s（%s）%s" % [label, value, "已满足" if met else "未满足",
			"" if tip.is_empty() else "\n" + tip])


func _draw_costs(x: float, w: float) -> void:
	var m := _model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var numeral := UITokens.dossier_font("numeral")
	var costs: Array = m.get("costs", [])
	if costs.is_empty():
		return
	_text(Vector2(x, COST_HEAD_Y), "晋升物资", strong, SIZE_BODY, UITokens.DOSSIER_INK, w)
	_region(Rect2(x, COST_HEAD_Y - 16.0, 80.0, 22.0),
		"%s；物资齐备后自动从国库扣除" % String(m.get("territory_note", "")))
	var overflow := costs.size() > MAX_COST_CHIPS
	var shown := MAX_COST_CHIPS - 1 if overflow else costs.size()
	# 签宽按实际签数均分：固定 4 等分时中文名（如「采集植物食物」）会被截断。
	var slots := MAX_COST_CHIPS if overflow else maxi(1, costs.size())
	var chip_w := floorf((w - 6.0 * float(slots - 1)) / float(slots))
	for i in range(shown):
		var row: Dictionary = costs[i]
		var rect := Rect2(x + float(i) * (chip_w + 6.0), COST_TOP, chip_w, COST_H)
		var done := bool(row.get("done", false))
		_chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		_chip_style.border_color = Color(UITokens.DOSSIER_VERDIGRIS, 0.5) if done \
			else Color(UITokens.DOSSIER_RULE, 0.5)
		_canvas.draw_style_box(_chip_style, rect)
		IconCatalog.draw_icon(_canvas, StringName(row.get("icon", &"system.unknown")),
			Rect2(rect.position.x + 5.0, rect.position.y + 9.0, 22.0, 22.0))
		var good_name := String(row.get("name", ""))
		var value := String(row.get("value_text", ""))
		var tx := rect.position.x + 31.0
		var inner := rect.end.x - 6.0 - tx
		_text(Vector2(tx, rect.position.y + 17.0), good_name, sans, SIZE_MINOR, UITokens.DOSSIER_INK,
			inner, HORIZONTAL_ALIGNMENT_LEFT,
			"%s：国库 %s / 需求 %s" % [good_name, String(row.get("stock_text", "0")),
				String(row.get("required_text", "0"))])
		_text(Vector2(tx, rect.position.y + 30.0), value, numeral, SIZE_MINOR,
			UITokens.DOSSIER_VERDIGRIS if done else UITokens.DOSSIER_INK, inner, HORIZONTAL_ALIGNMENT_RIGHT)
		var bar := Rect2(rect.position.x + 5.0, rect.end.y - 4.0, chip_w - 10.0, 2.0)
		_canvas.draw_rect(bar, UITokens.DOSSIER_TRACK)
		_canvas.draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(row.get("ratio", 0.0)), bar.size.y)),
			UITokens.DOSSIER_VERDIGRIS if done else UITokens.DOSSIER_BRASS)
		_region(rect, "%s：国库 %s / 需求 %s" % [good_name, String(row.get("stock_text", "0")),
			String(row.get("required_text", "0"))])
	if overflow:
		var rect := Rect2(x + float(shown) * (chip_w + 6.0), COST_TOP, chip_w, COST_H)
		_chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		_chip_style.border_color = Color(UITokens.DOSSIER_RULE, 0.5)
		_canvas.draw_style_box(_chip_style, rect)
		var lines := PackedStringArray()
		for i in range(shown, costs.size()):
			var row: Dictionary = costs[i]
			lines.append("%s：%s" % [String(row.get("name", "")), String(row.get("value_text", ""))])
		_text(Vector2(rect.position.x, rect.position.y + 26.0), "+%d 种" % (costs.size() - shown), sans,
			SIZE_BODY, UITokens.DOSSIER_INK_SOFT, chip_w, HORIZONTAL_ALIGNMENT_CENTER)
		_region(rect, "\n".join(lines))



## 加成逐条全列：≤4 条单列，否则两列（超出两列容量时三列），每条截断后全文进提示。
func _draw_buffs(x: float, w: float, head_y: float, heading: String) -> void:
	var sans := UITokens.dossier_font("sans")
	var buffs: PackedStringArray = _model.get("buffs", PackedStringArray())
	if buffs.is_empty():
		return
	_text(Vector2(x, head_y), heading, sans, SIZE_MINOR, UITokens.DOSSIER_BRASS.darkened(0.25), w)
	var columns := 1 if buffs.size() <= 4 else (2 if buffs.size() <= 2 * BUFF_MAX_ROWS else 3)
	var rows := int(ceil(float(buffs.size()) / float(columns)))
	var col_w := floorf((w - 12.0 * float(columns - 1)) / float(columns))
	for i in range(buffs.size()):
		var col := i / rows
		var row := i % rows
		var pos := Vector2(x + float(col) * (col_w + 12.0), head_y + 22.0 + float(row) * BUFF_LINE)
		_text(pos, "· " + String(buffs[i]), sans, SIZE_MINOR, UITokens.DOSSIER_INK, col_w,
			HORIZONTAL_ALIGNMENT_LEFT, String(buffs[i]))


func _draw_max(x: float, w: float) -> void:
	var current: Dictionary = _model.get("current", {})
	var side := 120.0
	var icon := _era_texture(String(current.get("id", "")))
	if icon != null:
		_canvas.draw_texture_rect(icon, Rect2(Vector2(x + (w - side) * 0.5, BAND_CENTER - 44.0),
			Vector2.ONE * side), false)
	_draw_buffs(x, w, COST_HEAD_Y - 40.0, "已获得的时代加成")
