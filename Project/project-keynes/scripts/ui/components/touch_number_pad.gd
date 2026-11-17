extends Control

## 触摸档的「游戏内数字键盘」——代替系统输入法。
##
## 为什么要自己造（真机反馈）：
##   点税率那一格会弹出安卓软键盘。软键盘加候选栏在横屏下占掉接近半屏，
##   而税率一行只有 30 设计像素高（≈13dp），被顶到键盘边缘之后
##   既看不见自己正在改哪个数字，也看不见隔壁那条税率；手指还要在
##   「输入框—键盘—确认」之间来回换位置。
##
## 现在整件事留在这张纸片里：按键 112×86 设计像素（≈56×43dp，按 1 设计像素 = 0.5dp
## 的既有标定），数值、单位、步进、口径、确认同屏，弹窗不因键盘而位移。
##
## 交互约定：
##   · 点纸片外、按 ESC / 安卓返回 = 取消，不改任何值（非破坏性）；
##   · 只有「确定」才提交，提交仍走宿主原有的解析 + 次日生效链路；
##   · 口径（% / 定额）也在这张纸片上切，跟着「确定」一起提交 ——
##     取消不会给存档留下半个「归零」状态；
##   · 只收整数：税率按 1 个百分点一档、定额按 1 金币一档，小数点没有用武之地。
##
## 不写 class_name：新脚本未进 global_script_class_cache 时裸类名编译会失败
## （同 mobile_ui_scaling.gd 的注释），统一由调用方 preload。

## 提交时把口径一起带出去：宿主据此换解析方式，不必先落一次「归零」命令。
signal submitted(text: String, mode: int)
signal dismissed()

const MODE_PERCENT := 0
const MODE_ABSOLUTE := 1
const KEY_SIZE := Vector2(112.0, 86.0)
const KEY_GAP := 8
## 主题必须自己挂：CanvasLayer 不是 Control，主题不会沿着它往下传，
## 所以本项目每个 UI 场景都在根节点自挂 player_session_theme（见 country_panel.tscn 等）。
## 这张纸片是纯代码构建的，同样得自己带上，否则 PKPaperPopup 取不到、面板退回默认深色。
const PAPER_THEME := preload("res://assets/themes/player_session_theme.tres")
const ACTION_KEY_WIDTH := 124.0
const MODE_KEY_HEIGHT := 50.0
const STEP_KEY_HEIGHT := 58.0
const VALUE_FONT_SIZE := 40
const UNIT_FONT_SIZE := 22
const KEY_FONT_SIZE := 24
const STEP_FONT_SIZE := 20
const MONEY_ICON_SIZE := 26
## 百分比最多「-1000」，定额最多十几位有效数字，14 字符足够且不会撑破读数行。
const MAX_TEXT_LEN := 14
const PANEL_MARGIN := 22.0

var _title := ""
var _suffix := ""
var _hint := ""
var _allow_negative := true
var _show_modes := false
var _mode := MODE_PERCENT
var _text := ""
var _built := false
## 显式状态：Control 建出来默认 visible=true，不能拿 visible 当「已打开」。
var _open := false
var _value_label: Label
var _unit_label: Label
var _hint_label: Label
var _mode_row: Control
var _money_icon: TextureRect
var _mode_keys: Dictionary = {}
var _confirm_key: Button


## ---------------------------------------------------------------- 对外

## config: title / suffix / value / hint / mode / show_modes / allow_negative
func open(config: Dictionary) -> void:
	_title = String(config.get("title", "调整数值"))
	_suffix = String(config.get("suffix", ""))
	_hint = String(config.get("hint", ""))
	_mode = int(config.get("mode", MODE_PERCENT))
	_show_modes = bool(config.get("show_modes", _mode != MODE_PERCENT))
	_allow_negative = bool(config.get("allow_negative", true))
	_text = String(config.get("value", "")).strip_edges()
	_build_once()
	_refresh()
	_open = true
	visible = true
	if is_inside_tree():
		grab_focus()
	if UIAnimation.reduced_motion():
		modulate = Color.WHITE
	else:
		modulate = Color(1.0, 1.0, 1.0, 0.0)
		UIAnimation.tween_modulate(self, Color.WHITE, UITokens.ANIM_FAST)


## 宿主切换口径之后回读：量纲变了，值会归零、单位会换（% ↔ 金币）。
func set_value(text: String, suffix: String, mode: int) -> void:
	_text = text.strip_edges()
	_suffix = suffix
	_mode = mode
	_refresh()


func close() -> void:
	_open = false
	visible = false
	_text = ""


func is_open() -> bool:
	return _open


## ---------------------------------------------------------------- 构建

func _build_once() -> void:
	if _built:
		return
	_built = true
	# 建好即隐藏：否则一个还没打开的键盘会连着半透明黑幕一起盖住整屏。
	visible = false
	theme = PAPER_THEME
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.03, 0.02, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	# 纸片皮肤走主题的 PKPaperPopup（撕纸边），不要自己 add_theme_stylebox_override。
	panel.theme_type_variation = &"PKPaperPopup"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_right", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_top", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_bottom", int(PANEL_MARGIN))
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"PKSectionTitle"
	column.add_child(title)
	title.text = _title

	column.add_child(_build_mode_row())
	column.add_child(_build_value_row())
	column.add_child(_build_hint_row())
	column.add_child(_build_step_row())
	column.add_child(_build_key_body())


## 口径切换：% ↔ 定额。选中态借 PKPrimaryButton（主题里的亮纸），未选中是普通纸片。
func _build_mode_row() -> Control:
	var row := HBoxContainer.new()
	row.name = "Modes"
	row.add_theme_constant_override("separation", KEY_GAP)
	for entry in [[MODE_PERCENT, "%"], [MODE_ABSOLUTE, "定额"]]:
		var mode: int = entry[0]
		var key := _make_key(String(entry[1]), STEP_FONT_SIZE, &"PKIconButton",
			func() -> void: _request_mode(mode))
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key.custom_minimum_size = Vector2(0.0, MODE_KEY_HEIGHT)
		row.add_child(key)
		_mode_keys[mode] = key
	_mode_row = row
	return row


func _build_value_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 6)
	_value_label = Label.new()
	_value_label.name = "Value"
	var numeral := UITokens.dossier_font("numeral")
	_value_label.add_theme_font_override("font", numeral)
	_value_label.add_theme_font_size_override("font_size", VALUE_FONT_SIZE)
	_value_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	row.add_child(_value_label)
	_unit_label = Label.new()
	_unit_label.name = "Unit"
	_unit_label.add_theme_font_override("font", numeral)
	_unit_label.add_theme_font_size_override("font_size", UNIT_FONT_SIZE)
	_unit_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_unit_label.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(_unit_label)
	# 定额税的单位是金币：和税率行一样用一枚图标顶着，不写「货币」二字。
	_money_icon = TextureRect.new()
	_money_icon.name = "MoneyIcon"
	_money_icon.custom_minimum_size = Vector2(MONEY_ICON_SIZE, MONEY_ICON_SIZE)
	_money_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_money_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_money_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_money_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_money_icon.visible = false
	MoneyDisplay.apply_icon(_money_icon, MONEY_ICON_SIZE)
	row.add_child(_money_icon)
	return row


func _build_hint_row() -> Control:
	# 继承税率是这一格最重要的参照：弹窗盖住了下面那行说明，所以在这里补一次。
	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.theme_type_variation = &"PKMutedLabel"
	_hint_label.add_theme_font_size_override("font_size", 14)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return _hint_label


func _build_step_row() -> Control:
	var row := HBoxContainer.new()
	row.name = "Steps"
	row.add_theme_constant_override("separation", KEY_GAP)
	var steps := [["-10", -10], ["-1", -1], ["+1", 1], ["+10", 10]]
	for entry in steps:
		var key := _make_key(String(entry[0]), KEY_FONT_SIZE, &"PKIconButton")
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key.custom_minimum_size = Vector2(0.0, STEP_KEY_HEIGHT)
		var delta: int = entry[1]
		key.pressed.connect(func() -> void: _step(delta))
		row.add_child(key)
	return row


func _build_key_body() -> Control:
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", KEY_GAP)

	var digits := VBoxContainer.new()
	digits.name = "Digits"
	digits.add_theme_constant_override("separation", KEY_GAP)
	body.add_child(digits)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", KEY_GAP)
	grid.add_theme_constant_override("v_separation", KEY_GAP)
	digits.add_child(grid)
	for digit in ["7", "8", "9", "4", "5", "6", "1", "2", "3"]:
		var key := _make_key(digit, KEY_FONT_SIZE, &"PKIconButton")
		key.pressed.connect(func() -> void: _push_digit(digit))
		grid.add_child(key)

	# 末行：0 占两格宽（手机键盘的惯例），右边那格原本放小数点，
	# 现在换成「补贴」—— 负税率就是倒给钱，玩家读这一格比读「负号」直接得多。
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", KEY_GAP)
	digits.add_child(bottom)
	var zero := _make_key("0", KEY_FONT_SIZE, &"PKIconButton",
		func() -> void: _push_digit("0"))
	zero.custom_minimum_size = Vector2(KEY_SIZE.x * 2.0 + KEY_GAP, KEY_SIZE.y)
	bottom.add_child(zero)
	bottom.add_child(_make_key("补贴", STEP_FONT_SIZE, &"PKIconButton", _toggle_sign))

	var actions := VBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", KEY_GAP)
	actions.custom_minimum_size.x = ACTION_KEY_WIDTH
	body.add_child(actions)
	var action_keys := [
		["退格", STEP_FONT_SIZE, &"PKIconButton", _backspace],
		["清空", STEP_FONT_SIZE, &"PKIconButton", _clear],
		["取消", STEP_FONT_SIZE, &"PKIconButton", _on_cancel_pressed],
		["确定", STEP_FONT_SIZE, &"PKPrimaryButton", _confirm],
	]
	for entry in action_keys:
		var key := _make_key(String(entry[0]), int(entry[1]), entry[2], entry[3])
		key.size_flags_vertical = Control.SIZE_EXPAND_FILL
		actions.add_child(key)
		if String(entry[0]) == "确定":
			_confirm_key = key
	return body


func _make_key(label: String, font_size: int, variation: StringName,
		on_press: Callable = Callable()) -> Button:
	var key := Button.new()
	key.text = label
	key.theme_type_variation = variation
	key.custom_minimum_size = KEY_SIZE
	# 键盘已经抢到焦点：按钮再抢会把数字键事件变成按钮激活，回车会连按两下。
	key.focus_mode = Control.FOCUS_NONE
	key.add_theme_font_size_override("font_size", font_size)
	if on_press.is_valid():
		key.pressed.connect(on_press)
	return key


## ---------------------------------------------------------------- 输入

func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		_dismiss()
		accept_event()
		return
	var key := event as InputEventKey
	if key == null:
		return
	_handle_key(key)
	accept_event()


## 安卓返回键 / 手柄 B 走 player_cancel，不一定落在有焦点的控件上，所以补一道。
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel") \
			or (InputMap.has_action(&"player_cancel") \
				and event.is_action_pressed(&"player_cancel")):
		_dismiss()
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key != null and _handle_key(key):
		get_viewport().set_input_as_handled()


func _handle_key(key: InputEventKey) -> bool:
	if not key.pressed or key.echo:
		return false
	match key.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_confirm()
		KEY_BACKSPACE:
			_backspace()
		KEY_MINUS, KEY_KP_SUBTRACT:
			_toggle_sign()
		_:
			var typed := String.chr(key.unicode)
			if typed.length() != 1 or typed < "0" or typed > "9":
				return false
			_push_digit(typed)
	return true


func _on_dim_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		_dismiss()


func _on_cancel_pressed() -> void:
	_dismiss()


## 换口径就是换量纲：12% 和 12 金币不是一回事，先把数量归零让玩家重新输。
func _request_mode(mode: int) -> void:
	if mode == _mode:
		return
	_mode = mode
	_text = "0"
	_refresh()


func _push_digit(digit: String) -> void:
	if _text.length() >= MAX_TEXT_LEN:
		return
	if _text == "0":
		_text = digit
	elif _text == "-0":
		_text = "-" + digit
	else:
		_text += digit
	_refresh()


func _toggle_sign() -> void:
	if not _allow_negative:
		return
	if _text.is_empty():
		_text = "0"
	if _text.begins_with("-"):
		_text = _text.substr(1)
	else:
		_text = "-" + _text
	_refresh()


func _backspace() -> void:
	if _text.is_empty():
		return
	_text = _text.substr(0, _text.length() - 1)
	_refresh()


func _clear() -> void:
	_text = ""
	_refresh()


func _step(delta: int) -> void:
	var current := _text.to_float() if _is_numeric(_text) else 0.0
	var next := current + float(delta)
	if not _allow_negative:
		next = maxf(next, 0.0)
	_text = _format_number(next)
	_refresh()


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return "%d" % int(roundf(value))
	var shown := "%.2f" % value
	return shown.trim_suffix("0").trim_suffix(".")


func _is_numeric(text: String) -> bool:
	var trimmed := text.strip_edges()
	return trimmed.is_valid_int() or trimmed.is_valid_float()


func _refresh() -> void:
	if _value_label == null:
		return
	var absolute := _mode == MODE_ABSOLUTE
	_value_label.text = _text if not _text.is_empty() else "0"
	# 百分比档的单位是 "%" 本身，不依赖宿主传进来的 suffix：
	# 从定额档切回百分比时，宿主当初传的 suffix 是空的（定额没有单位后缀）。
	_unit_label.text = "" if absolute else (_suffix if not _suffix.is_empty() else "%")
	_unit_label.visible = not absolute
	_money_icon.visible = absolute
	_mode_row.visible = _show_modes
	# 定额档不显示「国家默认 10%」：那是百分比口径的参照，和金币数量同屏会被读成一个量纲。
	_hint_label.text = "" if absolute else _hint
	_hint_label.visible = not absolute and not _hint.is_empty()
	for mode in _mode_keys.keys():
		var key := _mode_keys[mode] as Button
		var active := int(mode) == _mode
		key.theme_type_variation = &"PKPrimaryButton" if active else &"PKIconButton"
	if _confirm_key != null:
		_confirm_key.disabled = not _is_numeric(_text)


## ---------------------------------------------------------------- 提交

func _confirm() -> void:
	if not _is_numeric(_text):
		return
	var result := _text
	var mode := _mode
	_text = ""
	_open = false
	visible = false
	submitted.emit(result, mode)


func _dismiss() -> void:
	if not _open:
		return
	_text = ""
	_open = false
	visible = false
	dismissed.emit()
