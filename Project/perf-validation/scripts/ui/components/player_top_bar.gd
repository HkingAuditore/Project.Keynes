extends PanelContainer
class_name PlayerTopBar

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal setup_requested()
signal gm_requested()

const BAR_HEIGHT := 56.0
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
	if not has_node("Margin/Row/DateBlock/DateLabel"):
		push_error("PlayerTopBar 必须通过 player_top_bar.tscn 实例化。")
		return

	_date_label = %DateLabel
	_pause_button = %PauseButton
	_day_night_button = %DayNightButton
	_gm_button = %GMButton
	_date_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	IconButton.apply(%SetupButton, &"settings", 15, "设置")
	IconButton.apply(_gm_button, &"overview", 15, "GM 面板（F1 / `）")
	IconButton.apply(_day_night_button, &"moon", 15, "昼夜循环：开启", true, true)
	IconButton.apply(_pause_button, &"pause", 15, "暂停", true, false)
	%SetupButton.focus_mode = Control.FOCUS_NONE
	_gm_button.focus_mode = Control.FOCUS_NONE
	_day_night_button.focus_mode = Control.FOCUS_NONE
	_pause_button.focus_mode = Control.FOCUS_NONE
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
		button.pressed.connect(_on_speed_pressed.bind(speed))
		_speed_buttons[speed] = button
	set_gm_available(_gm_available)


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
	IconButton.apply(
		_pause_button,
		&"action.play" if paused else &"action.pause",
		15,
		"继续" if paused else "暂停",
		true,
		paused
	)
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


func _on_speed_pressed(speed: float) -> void:
	speed_selected.emit(speed)
