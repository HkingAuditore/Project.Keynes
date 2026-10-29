extends PanelContainer
class_name PlayerTopBar

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal setup_requested()
signal gm_requested()
signal annual_history_requested()

const BAR_HEIGHT := 80.0
const SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0]
const HUD_ICON_SIZE := 36

var _calendar_icon: TextureRect
var _date_label: Label
var _date_button: Button
var _date_row: HBoxContainer
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
	_era_name.add_theme_font_size_override("font_size", UITokens.FONT_HUD_TIME)
	_era_name.add_theme_color_override("font_color", UITokens.HUD_INK)
	_date_button = $Margin/Row/DateBlock as Button
	_date_row = $Margin/Row/DateBlock/DateRow as HBoxContainer
	_date_row.minimum_size_changed.connect(_update_date_block_width)
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
	_date_label.add_theme_font_size_override("font_size", UITokens.FONT_HUD_TIME)
	_date_label.add_theme_color_override("font_color", UITokens.HUD_INK)
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


func era_name_target() -> Control:
	return _era_name


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
	_date_button.custom_minimum_size.x = maxf(252.0, _date_row.get_combined_minimum_size().x + 20.0)


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
