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
## 百分比和定额共用的输入长度。
const MAX_TEXT_LEN := 14

var _suffix := ""
var _hint := ""
var _allow_negative := true
var _show_modes := false
var _mode := MODE_PERCENT
var _text := ""
var _open := false
@onready var _value_label: Label = %Value
@onready var _unit_label: Label = %Unit
@onready var _hint_label: Label = %Hint
@onready var _mode_row: Control = %Modes
@onready var _money_icon: TextureRect = %MoneyIcon
@onready var _mode_keys: Dictionary = {int(MODE_PERCENT): %Percent, int(MODE_ABSOLUTE): %Absolute}
@onready var _confirm_key: Button = %Confirm


func _ready() -> void:
	var numeral := UITokens.dossier_font("numeral")
	_value_label.add_theme_font_override("font", numeral)
	_unit_label.add_theme_font_override("font", numeral)
	MoneyDisplay.apply_icon(_money_icon, 26)


## ---------------------------------------------------------------- 对外

## config: title / suffix / value / hint / mode / show_modes / allow_negative
func open(config: Dictionary) -> void:
	%Title.text = String(config.get("title", "调整数值"))
	_suffix = String(config.get("suffix", ""))
	_hint = String(config.get("hint", ""))
	_mode = int(config.get("mode", MODE_PERCENT))
	_show_modes = bool(config.get("show_modes", _mode != MODE_PERCENT))
	_allow_negative = bool(config.get("allow_negative", true))
	_text = String(config.get("value", "")).strip_edges()
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


## ---------------------------------------------------------------- 输入

func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		_dismiss()
		accept_event()
		return
	var key := event as InputEventKey
	if key != null and _handle_key(key):
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
