extends PanelContainer
class_name PlayerTopBar

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal setup_requested()
signal gm_requested()

const BAR_HEIGHT := 48.0
const SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0]

var _date_label: Label
var _pause_button: Button
var _day_night_button: Button
var _gm_button: Button
var _speed_buttons: Dictionary = {}
var _gm_available := true


func _ready() -> void:
	if _date_label != null:
		return
	name = "PlayerTopBar"
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bar_style := UITokens.panel_style(
		Color(0.030, 0.028, 0.024, 0.975),
		UITokens.RADIUS_SM,
		Color(0.56, 0.42, 0.22, 0.86)
	)
	_zero_style_margins(bar_style)
	add_theme_stylebox_override("panel", bar_style)
	if not has_node("Margin/Row/DateBlock/DateLabel"):
		_build_compatibility_tree()
		return

	_date_label = %DateLabel
	_pause_button = %PauseButton
	_day_night_button = %DayNightButton
	_gm_button = %GMButton
	var date_style := UITokens.inset_panel_style(
		Color(0.055, 0.048, 0.039, 0.94), UITokens.PANEL_BORDER_SOFT)
	_zero_style_margins(date_style)
	date_style.content_margin_left = UITokens.SPACE_MD
	date_style.content_margin_right = UITokens.SPACE_MD
	date_style.content_margin_top = 2
	date_style.content_margin_bottom = 2
	$Margin/Row/DateBlock.add_theme_stylebox_override("panel", date_style)
	_date_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_date_label.add_theme_font_size_override("font_size", UITokens.FONT_HUD_TIME)
	_date_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	IconButton.apply(%SetupButton, &"settings", 15, "设置")
	IconButton.apply(_gm_button, &"overview", 15, "GM 面板（F1 / `）")
	IconButton.apply(_day_night_button, &"moon", 15, "昼夜循环：开启", true, true)
	IconButton.apply(_pause_button, &"pause", 15, "暂停", true, false)
	%SetupButton.pressed.connect(func() -> void: setup_requested.emit())
	_gm_button.pressed.connect(func() -> void: gm_requested.emit())
	_day_night_button.toggled.connect(func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_pause_button.toggled.connect(func(pressed: bool) -> void: pause_toggled.emit(pressed))
	var speed_nodes := [%Speed1, %Speed2, %Speed5, %Speed10, %Speed20, %Speed50]
	for index in range(SPEED_PRESETS.size()):
		var speed := SPEED_PRESETS[index]
		var button := speed_nodes[index] as Button
		button.tooltip_text = "%d 倍速" % int(speed)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		button.pressed.connect(_on_speed_pressed.bind(speed))
		_speed_buttons[speed] = button
	set_gm_available(_gm_available)


func _build_compatibility_tree() -> void:
	# The product scene uses the authored tree. Keep direct `new()` usable by
	# isolated component tests and external tools that do not load the scene.
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(row)
	row.add_child(_build_date_block())
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_build_control_block())


func set_world_summary(_width: int, _height: int, _cells: int, _seed: int) -> void:
	pass


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
	_pause_button.set_pressed_no_signal(paused)
	IconButton.apply(_pause_button, &"action.play" if paused else &"action.pause", 15)
	_pause_button.tooltip_text = "继续" if paused else "暂停"
	for speed_key in _speed_buttons.keys():
		var button := _speed_buttons[speed_key] as Button
		if button != null:
			button.set_pressed_no_signal(is_equal_approx(float(speed_key), speed))


func bar_height() -> float:
	return BAR_HEIGHT


func set_day_night_enabled(enabled: bool) -> void:
	if _day_night_button == null:
		_ready()
	var tooltip := "昼夜循环：%s" % (
		"开启" if enabled else "关闭（动态永昼，光向随直射点移动）"
	)
	# IconButton.apply() 默认会把按钮配置成非 toggle；这里必须显式保留 toggle
	# 语义，否则首次运行时状态同步后，顶栏按钮将不再发出 toggled 信号。
	IconButton.apply(
		_day_night_button,
		&"climate.moon" if enabled else &"climate.sun",
		15,
		tooltip,
		true,
		enabled
	)


func set_gm_available(available: bool) -> void:
	_gm_available = available
	if _gm_button != null:
		_gm_button.visible = available
		_gm_button.disabled = not available


func _build_date_block() -> Control:
	var block := PanelContainer.new()
	var block_style := UITokens.inset_panel_style(Color(0.055, 0.048, 0.039, 0.94), UITokens.PANEL_BORDER_SOFT)
	_zero_style_margins(block_style)
	block_style.content_margin_left = UITokens.SPACE_MD
	block_style.content_margin_right = UITokens.SPACE_MD
	block_style.content_margin_top = 2
	block_style.content_margin_bottom = 2
	block.add_theme_stylebox_override("panel", block_style)

	_date_label = Label.new()
	_date_label.text = "第1年 · 第1日"
	_date_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_date_label.add_theme_font_size_override("font_size", UITokens.FONT_HUD_TIME)
	_date_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	block.add_child(_date_label)
	return block


func _build_control_block() -> Control:
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 4)

	var setup_button := _icon_button("settings", "设置")
	setup_button.pressed.connect(func() -> void: setup_requested.emit())
	controls.add_child(setup_button)

	_gm_button = _icon_button("overview", "GM 面板（F1 / `）")
	_gm_button.visible = _gm_available
	_gm_button.disabled = not _gm_available
	_gm_button.pressed.connect(func() -> void: gm_requested.emit())
	controls.add_child(_gm_button)

	_day_night_button = _icon_button("moon", "昼夜循环：开启")
	_day_night_button.toggle_mode = true
	_day_night_button.button_pressed = true
	_day_night_button.toggled.connect(func(enabled: bool) -> void:
		day_night_toggled.emit(enabled)
	)
	controls.add_child(_day_night_button)

	var divider := VSeparator.new()
	divider.custom_minimum_size = Vector2(8.0, 0.0)
	divider.add_theme_color_override("separator", UITokens.PANEL_BORDER_SOFT)
	controls.add_child(divider)

	_pause_button = _icon_button("pause", "暂停")
	_pause_button.toggle_mode = true
	_pause_button.toggled.connect(func(pressed: bool) -> void: pause_toggled.emit(pressed))
	controls.add_child(_pause_button)

	for speed in SPEED_PRESETS:
		var button := Button.new()
		button.text = "%d" % int(speed)
		button.tooltip_text = "%d 倍速" % int(speed)
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(34.0, 30.0)
		button.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		button.pressed.connect(_on_speed_pressed.bind(speed))
		controls.add_child(button)
		_speed_buttons[speed] = button
	return controls


func _icon_button(icon_key: String, tooltip: String) -> Button:
	var button := Button.new()
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(34.0, 30.0)
	IconButton.apply(button, StringName(icon_key), 15, tooltip)
	return button


func _on_speed_pressed(speed: float) -> void:
	speed_selected.emit(speed)


func _zero_style_margins(style: StyleBoxFlat) -> void:
	style.content_margin_left = 0
	style.content_margin_top = 0
	style.content_margin_right = 0
	style.content_margin_bottom = 0
