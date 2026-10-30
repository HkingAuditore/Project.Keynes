extends PanelContainer
class_name PlayerTopBar

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal setup_requested()
signal gm_requested()
signal annual_history_requested()
## 国库/人口纸签：hover 出明细悬浮卡，点击进入对应的国家经济分页。
signal status_hovered(kind: String, entered: bool)
signal status_pressed(kind: String)

const TREASURY_ICON := preload("res://assets/ui/country_status/Gold.png")
const POPULATION_ICON := preload("res://assets/ui/country_status/Population.png")
const BAR_HEIGHT := 80.0
const SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0]
const HUD_ICON_SIZE := 36

# ── 日历块（日期 + 时代）的排印契约 ───────────────────────────────────
# 这里全部按"实测字宽"推导，不再写死 108/250 这种魔法宽度：顶栏曾经因为
# DateLabel 的 108 最小值装不下"第1年 · 1月1日"（实测 117px）而把日期裁成
# "第1年 · 1月…"，时代名再把剩下那点空间挤掉。现在：
#   纸框宽度 = 图标 + 段间距 + 日期字宽 + 时代字宽 + DateRow 左右留白（.tscn 的
#   offset_left/right），只向大取，绝不压到内容之下；每个 Label 还多给
#   DATE_BLOCK_TEXT_SLACK 的余量，保证字形右侧不会贴到纸边。
# 横向真放不下时先整体降字号，降到地板仍不够就让纸框变宽——不裁字。
const DATE_FONT_SIZE := 18
const DATE_FONT_MIN_SIZE := 14
const ERA_FONT_SIZE := 14
const ERA_FONT_MIN_SIZE := 11
const DATE_BLOCK_MIN_WIDTH := 200.0
const DATE_BLOCK_MAX_WIDTH := 340.0
const DATE_BLOCK_TAIL_GUTTER := 24.0
const DATE_BLOCK_TEXT_SLACK := 3.0
const DATE_TEXT_FALLBACK := "第1年 · 1月1日"

# ── 国库/人口纸签的排印契约 ───────────────────────────────────────────
# 和日历块同一条规则，只是这里量的是读数：纸签宽度 = Row 左右留白 + 图标 +
# 段间距 + 读数实测字宽，只向大取。写死 108/94 的时候，"12.35万" 实测 85px
# 而可用只有 61px，读数直接顶出纸边，人口数被纸框切掉半个字。数字统一按最宽
# 字形 8 预留，位数不变时纸签宽度不随读数抖动。
const STATUS_FONT_SIZE := 23
const STATUS_TEXT_SLACK := 5.0
const TREASURY_PLATE_MIN_WIDTH := 108.0
const POPULATION_PLATE_MIN_WIDTH := 94.0

var _calendar_icon: TextureRect
var _date_label: Label
var _date_button: Button
var _date_row: HBoxContainer
var _treasury_button: Button
var _treasury_icon: TextureRect
var _treasury_value: Label
var _population_button: Button
var _population_icon: TextureRect
var _population_value: Label
var _pause_button: Button
var _speed_button: Button
var _day_night_button: Button
var _gm_button: Button
var _setup_button: Button
var _current_speed := 1.0
var _is_paused := false
var _gm_available := false
var _era_name: Label
var _era_flash: Tween
var _fitting_calendar := false
var _applied_date_font_size := DATE_FONT_SIZE
var _applied_era_font_size := ERA_FONT_SIZE
var _applied_block_width := -1.0


func _ready() -> void:
	if _date_label != null:
		return
	name = "PlayerTopBar"
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if get_node_or_null("%DateLabel") == null:
		push_error("PlayerTopBar 必须通过 player_top_bar.tscn 实例化。")
		return

	_calendar_icon = %CalendarIcon
	_date_label = %DateLabel
	_era_name = %EraName
	_era_name.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_era_name.add_theme_font_size_override("font_size", ERA_FONT_SIZE)
	_era_name.add_theme_color_override("font_color", UITokens.HUD_INK)
	_date_button = $Margin/Row/DateBlock as Button
	_date_row = $Margin/Row/DateBlock/DateRow as HBoxContainer
	_treasury_button = %TreasuryButton
	_treasury_icon = $Margin/Row/CountryStatus/TreasuryButton/Row/Icon
	_treasury_value = %TreasuryValue
	_population_button = %PopulationButton
	_population_icon = $Margin/Row/CountryStatus/PopulationButton/Row/Icon
	_population_value = %PopulationValue
	_date_row.minimum_size_changed.connect(_update_date_block_width)
	resized.connect(_update_date_block_width)
	_date_button.tooltip_text = "查阅历年发展报告"
	_date_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_date_button.focus_mode = Control.FOCUS_ALL
	_date_button.pressed.connect(func() -> void: annual_history_requested.emit())
	_date_button.mouse_entered.connect(func() -> void: _date_label.add_theme_color_override("font_color", UITokens.CHRONICLE_RED))
	_date_button.mouse_exited.connect(func() -> void: _date_label.add_theme_color_override("font_color", UITokens.HUD_INK))
	_pause_button = %PauseButton
	_speed_button = %SpeedCycleButton
	_day_night_button = %DayNightButton
	_gm_button = %GMButton
	_setup_button = %SetupButton

	if _calendar_icon != null:
		_calendar_icon.texture = IconCatalog.texture_for_key(&"hud.clock.calendar")
		_calendar_icon.modulate = Color.WHITE
	_date_label.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_date_label.add_theme_font_size_override("font_size", DATE_FONT_SIZE)
	_date_label.add_theme_color_override("font_color", UITokens.HUD_INK)
	_treasury_icon.texture = TREASURY_ICON
	_population_icon.texture = POPULATION_ICON
	for status_value in [_treasury_value, _population_value]:
		status_value.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
		status_value.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
		status_value.add_theme_color_override("font_color", UITokens.HUD_INK)
	for status_button in [_treasury_button, _population_button]:
		status_button.focus_mode = Control.FOCUS_NONE
		status_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_treasury_button.mouse_entered.connect(
		func() -> void: status_hovered.emit("treasury", true))
	_treasury_button.mouse_exited.connect(
		func() -> void: status_hovered.emit("treasury", false))
	_treasury_button.pressed.connect(func() -> void: status_pressed.emit("treasury"))
	_population_button.mouse_entered.connect(
		func() -> void: status_hovered.emit("population", true))
	_population_button.mouse_exited.connect(
		func() -> void: status_hovered.emit("population", false))
	_population_button.pressed.connect(func() -> void: status_pressed.emit("population"))
	_update_status_plates()
	_update_date_block_width()

	_speed_button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_speed_button.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)

	# 昼夜循环按钮通过日月剪纸图标本身表达状态，不占用暗红告警激活底色。
	var normal_sb := get_theme_stylebox("normal", &"PKHUDButton")
	var hover_sb := get_theme_stylebox("hover", &"PKHUDButton")
	if normal_sb != null:
		_day_night_button.add_theme_stylebox_override("pressed", normal_sb)
	if hover_sb != null:
		_day_night_button.add_theme_stylebox_override("hover_pressed", hover_sb)

	IconButton.apply(
		_setup_button, &"hud.system.settings", HUD_ICON_SIZE, "系统菜单（Esc）")
	IconButton.apply(
		_gm_button, &"hud.system.gm", HUD_ICON_SIZE, "GM 调试面板（F1 / `）")
	set_day_night_enabled(true)
	_apply_clock_controls(false, 1.0)

	for control_btn in [_setup_button, _gm_button, _day_night_button, _pause_button, _speed_button]:
		if control_btn != null:
			control_btn.focus_mode = Control.FOCUS_NONE
			control_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			UIAnimation.bind_tactile_button(control_btn)

	_setup_button.pressed.connect(func() -> void: setup_requested.emit())
	_gm_button.pressed.connect(func() -> void: gm_requested.emit())
	_day_night_button.toggled.connect(func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_pause_button.toggled.connect(func(pressed: bool) -> void: pause_toggled.emit(pressed))
	_speed_button.pressed.connect(cycle_speed_forward)
	_speed_button.gui_input.connect(_on_speed_button_gui_input)
	set_gm_available(false)


func set_world_summary(_width: int, _height: int, _cells: int, _seed: int) -> void:
	pass


func set_country_status(cash: float, cash_valid: bool,
		population: int, population_valid: bool) -> void:
	# 读数只写紧凑文本；口径解释交给 hover 卡（收支明细 / 阶层构成），
	# 纸签本身不挂 tooltip，免得悬停时同时弹出两套说明。
	var cash_text := UITokens.format_compact_number_cn(cash / 10000.0, 2) \
		if cash_valid else "—"
	var population_text := UITokens.format_compact_number_cn(float(population), 0) \
		if population_valid else "—"
	_set_status_value(_treasury_value, cash_text)
	_set_status_value(_population_value, population_text)
	_update_status_plates()
	_update_date_block_width()


## 两块读数的纸签按实测字宽定宽：图标与留白占固定部分，读数占其余，
## 数据变长（12.35万 → 888.88万、6789 → 1234 万）时纸签跟着长大，绝不裁字。
func _update_status_plates() -> void:
	_fit_status_plate(_treasury_button, _treasury_value, _treasury_icon,
		TREASURY_PLATE_MIN_WIDTH)
	_fit_status_plate(_population_button, _population_value, _population_icon,
		POPULATION_PLATE_MIN_WIDTH)


func _fit_status_plate(button: Button, value: Label, icon: TextureRect,
		min_width: float) -> void:
	if button == null or value == null:
		return
	var text_width := ceilf(_text_width(value,
		_reserved_status_text(value.text),
		value.get_theme_font_size(&"font_size"))) + STATUS_TEXT_SLACK
	value.custom_minimum_size.x = text_width
	var inner := text_width
	if icon != null:
		inner += icon.custom_minimum_size.x
	var row := button.get_node_or_null("Row") as HBoxContainer
	if row != null:
		inner += maxf(float(row.get_theme_constant(&"separation")), 0.0) \
			+ row.offset_left - row.offset_right
	button.custom_minimum_size.x = maxf(min_width, ceilf(inner))


## 读数每天变，纸签宽度不该跟着抖：数字一律换成最宽的字形 8 来量。
func _reserved_status_text(text: String) -> String:
	if text.is_empty():
		return "8"
	var reserved := ""
	for i in text.length():
		var glyph := text.substr(i, 1)
		reserved += "8" if glyph in "0123456789" else glyph
	return reserved


func _set_status_value(label: Label, text_value: String) -> void:
	if label.text == text_value:
		return
	label.text = text_value
	if UIAnimation.reduced_motion():
		return
	var old_tween = label.get_meta("_country_status_tween") \
		if label.has_meta("_country_status_tween") else null
	if old_tween is Tween and old_tween.is_valid():
		old_tween.kill()
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.08, 1.08)
	label.modulate = Color(1.16, 1.08, 0.84, 1.0)
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	label.set_meta("_country_status_tween", tween)
	tween.tween_property(label, "scale", Vector2.ONE, 0.16)
	tween.parallel().tween_property(label, "modulate", Color.WHITE, 0.22)


func era_name_target() -> Control:
	return _era_name


## 悬浮卡贴在对应纸签下方，所以要把纸签的真实矩形交给卡片。
func status_anchor(kind: String) -> Rect2:
	var button := _population_button if kind == "population" else _treasury_button
	if button == null:
		return Rect2()
	return button.get_global_rect()


func set_era_name(era_name: String, celebrate: bool = false) -> void:
	if _era_name == null:
		return
	if _era_name.text == era_name and not celebrate:
		return
	_era_name.text = era_name
	_update_date_block_width()
	if _era_flash != null and _era_flash.is_valid():
		_era_flash.kill()
	_era_name.modulate = Color.WHITE
	_era_name.scale = Vector2.ONE
	if not celebrate:
		return
	_era_name.pivot_offset = _era_name.size * 0.5
	_era_name.modulate = UITokens.ERA_BADGE_GOLD
	_era_name.scale = Vector2(1.14, 1.14)
	_era_flash = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_era_flash.tween_property(_era_name, "scale", Vector2.ONE, 0.55)
	_era_flash.tween_property(_era_name, "modulate", Color.WHITE, 0.8)


func update_time_state(
		year_idx: int,
		month: int,
		day_of_month: int,
		paused: bool,
		speed: float
) -> void:
	if _date_label == null:
		_ready()
	_date_label.text = "第%d年 · %d月%d日" % [year_idx + 1, month, day_of_month]
	_update_date_block_width()
	_apply_clock_controls(paused, speed)


func _update_date_block_width() -> void:
	# Button 不会从子容器继承最小宽度；日期和时代名一起撑开纸框。
	#
	# 硬契约：纸框宽度永远等于"图标 + 两段间距 + 日期字宽 + 时代字宽 + 左右留白"，
	# 只允许往上长，绝不允许压到内容之下。所以字一定在框内，且两边各有
	# DATE_ROW 的 offset 作为可视留白；字号只在顶栏横向吃紧时整体降级，
	# 降到地板（DATE_FONT_MIN_SIZE / ERA_FONT_MIN_SIZE）后宁可让纸框变宽，
	# 也不裁字或让文字压到纸边。
	if _date_button == null or _date_label == null or _era_name == null:
		return
	if _fitting_calendar:
		return
	_fitting_calendar = true
	var chrome := _calendar_chrome_width()
	var limit := clampf(_calendar_block_free_width(), DATE_BLOCK_MIN_WIDTH, DATE_BLOCK_MAX_WIDTH)
	var reserved_date := _reserved_date_text()
	var date_size := DATE_FONT_SIZE
	var era_size := ERA_FONT_SIZE
	var need := chrome + _calendar_text_width(reserved_date, date_size, era_size)
	while need > limit and date_size > DATE_FONT_MIN_SIZE:
		date_size -= 1
		era_size = maxi(ERA_FONT_MIN_SIZE,
			roundi(float(date_size) * float(ERA_FONT_SIZE) / float(DATE_FONT_SIZE)))
		need = chrome + _calendar_text_width(reserved_date, date_size, era_size)
	var width := maxf(need, DATE_BLOCK_MIN_WIDTH)
	if date_size == _applied_date_font_size and era_size == _applied_era_font_size \
			and is_equal_approx(width, _applied_block_width):
		_fitting_calendar = false
		return
	_applied_date_font_size = date_size
	_applied_era_font_size = era_size
	_applied_block_width = width
	_date_label.add_theme_font_size_override("font_size", date_size)
	_era_name.add_theme_font_size_override("font_size", era_size)
	_date_label.custom_minimum_size.x = ceilf(
		_text_width(_date_label, reserved_date, date_size)) + DATE_BLOCK_TEXT_SLACK
	_era_name.custom_minimum_size.x = ceilf(
		_text_width(_era_name, _era_name.text, era_size)) + DATE_BLOCK_TEXT_SLACK
	_date_button.custom_minimum_size.x = width
	_fitting_calendar = false


func _calendar_text_width(date_text: String, date_size: int, era_size: int) -> float:
	return _text_width(_date_label, date_text, date_size) \
		+ _text_width(_era_name, _era_name.text, era_size) \
		+ DATE_BLOCK_TEXT_SLACK * 2.0


## 图标 + 段间距 + DateRow 左右内边距，即块内不可压缩的固定宽度。
func _calendar_chrome_width() -> float:
	var icon_width := float(HUD_ICON_SIZE)
	if _calendar_icon != null and _calendar_icon.custom_minimum_size.x > 0.0:
		icon_width = _calendar_icon.custom_minimum_size.x
	var separation := maxf(float(_date_row.get_theme_constant(&"separation")), 0.0)
	var side_pad := _date_row.offset_left - _date_row.offset_right
	return icon_width + separation * 2.0 + side_pad


## 顶栏这一行里，日历块最多能拿到多宽：整行宽度减去库房/人口/控制按钮的
## 实际最小宽度、间距，再留一点贴边呼吸。
func _calendar_block_free_width() -> float:
	var row := _date_button.get_parent() as Control
	var available := row.size.x if row != null else 0.0
	if available <= 1.0:
		available = maxf(get_viewport_rect().size.x - 32.0, 0.0)
	var reserved := 0.0
	if row is HBoxContainer:
		var box := row as HBoxContainer
		var visible_count := 0
		for child in box.get_children():
			var control := child as Control
			if control == null or not control.visible:
				continue
			visible_count += 1
			if control != _date_button:
				reserved += control.get_combined_minimum_size().x
		reserved += float(maxi(visible_count - 1, 0)) \
			* maxf(float(box.get_theme_constant(&"separation")), 0.0)
	return maxf(available - reserved - DATE_BLOCK_TAIL_GUTTER, 0.0)


func _text_width(label: Label, text: String, font_size: int) -> float:
	if label == null or text.is_empty():
		return 0.0
	var font := label.get_theme_font(&"font")
	if font == null:
		return float(font_size) * float(text.length())
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x


## 日期每天都变，但"最宽的那一天"是固定的：数字都换成最宽的字形 8，
## 月/日一律按两位预留（1 日 → 28 日、1 月 → 12 月纸框都不许跳），
## 年号保留实际位数（只在第 9→10、99→100 年变一次）。
func _reserved_date_text() -> String:
	var text: String = _date_label.text
	if text.is_empty():
		text = DATE_TEXT_FALLBACK
	var reserved := ""
	var run_index := 0
	var i := 0
	while i < text.length():
		var glyph := text.substr(i, 1)
		if glyph in "0123456789":
			var run_length := 0
			while i < text.length() and text.substr(i, 1) in "0123456789":
				run_length += 1
				i += 1
			var digits := run_length if run_index == 0 else maxi(run_length, 2)
			reserved += "8".repeat(digits)
			run_index += 1
		else:
			reserved += glyph
			i += 1
	return reserved


func _apply_clock_controls(paused: bool, speed: float) -> void:
	_is_paused = paused
	_current_speed = speed
	var speed_int := int(round(_current_speed))
	IconButton.apply(
		_pause_button,
		&"hud.clock.play" if paused else &"hud.clock.pause",
		HUD_ICON_SIZE,
		"继续演化（空格）" if paused else "暂停演化（空格）",
		true,
		paused
	)
	var next_speed := int(round(_adjacent_speed(_current_speed, 1)))
	var prev_speed := int(round(_adjacent_speed(_current_speed, -1)))
	var speed_tooltip := "当前 %d 倍速\n左键切换至 %d× · 右键回退至 %d×" % [
		speed_int, next_speed, prev_speed
	]
	_speed_button.icon = null
	_speed_button.text = "%d×" % speed_int
	_speed_button.tooltip_text = speed_tooltip


func cycle_speed_forward() -> void:
	var next_speed := _adjacent_speed(_current_speed, 1)
	_current_speed = next_speed
	_apply_clock_controls(_is_paused, _current_speed)
	speed_selected.emit(next_speed)


func cycle_speed_backward() -> void:
	var prev_speed := _adjacent_speed(_current_speed, -1)
	_current_speed = prev_speed
	_apply_clock_controls(_is_paused, _current_speed)
	speed_selected.emit(prev_speed)


func current_speed() -> float:
	return _current_speed


func _on_speed_button_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			cycle_speed_backward()
			_speed_button.accept_event()


func _snap_speed(speed: float) -> float:
	var best := SPEED_PRESETS[0]
	var best_diff := absf(speed - best)
	for candidate in SPEED_PRESETS:
		var diff := absf(speed - candidate)
		if diff < best_diff:
			best = candidate
			best_diff = diff
	return best


func _adjacent_speed(speed: float, step: int) -> float:
	var snapped := _snap_speed(speed)
	var idx := SPEED_PRESETS.find(snapped)
	if idx < 0:
		idx = 0
	var next_idx := posmod(idx + step, SPEED_PRESETS.size())
	return SPEED_PRESETS[next_idx]


func bar_height() -> float:
	return BAR_HEIGHT


func set_day_night_enabled(enabled: bool) -> void:
	if _day_night_button == null:
		_ready()
	var tooltip := "昼夜循环：%s" % (
		"开启（动态永昼）" if enabled else "关闭（动态永昼，光向随直射点移动）"
	)
	IconButton.apply(
		_day_night_button,
		&"hud.system.day_night_on" if enabled else &"hud.system.day_night_off",
		HUD_ICON_SIZE,
		tooltip,
		true,
		enabled
	)


func set_gm_available(_available: bool) -> void:
	# GM 面板仅在调试时通过键盘（F1 / `）呼出，不在 HUD 顶栏显示按钮。
	_gm_available = false
	if _gm_button != null:
		_gm_button.visible = false
		_gm_button.disabled = true
