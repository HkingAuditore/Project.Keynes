extends Control

## 触摸端侧滑调税抽屉：将一张税卡上的 1~3 条税道（交易/进口/出口或单一税种）收进宽敞面板集中编辑。

const TouchNumberPad = preload("res://scenes/ui/touch_number_pad.tscn")
const MODE_PERCENT := 0
const MODE_ABSOLUTE := 1
const PERCENT_PRESETS := [0, 5, 10, 15, 20]
const ABSOLUTE_PRESETS := [0, 1, 5, 10, 50]

@onready var _shade: Control = %Shade
@onready var _title: Label = %Title
@onready var _close: Button = %CloseButton
@onready var _lane_row: Control = %LaneRow
@onready var _lane_buttons: Array[Button] = [%Lane0, %Lane1, %Lane2]
@onready var _kind_caption: Label = %KindCaption
@onready var _money_icon: TextureRect = %MoneyIcon
@onready var _value_label: Label = %ValueLabel
@onready var _unit_label: Label = %UnitLabel
@onready var _hint_label: Label = %HintLabel
@onready var _mode_percent: Button = %ModePercent
@onready var _mode_absolute: Button = %ModeAbsolute
@onready var _preset_buttons: Array[Button] = [%Preset0, %Preset1, %Preset2, %Preset3, %Preset4]
@onready var _minus_5: Button = %Minus5
@onready var _minus_1: Button = %Minus1
@onready var _plus_1: Button = %Plus1
@onready var _plus_5: Button = %Plus5
@onready var _keypad_btn: Button = %KeypadButton
@onready var _reset_btn: Button = %ResetButton
@onready var _confirm_btn: Button = %ConfirmButton

## lanes: Array of {kind, label, value_text, mode, hint, can_reset, commit: Callable(text, mode), reset: Callable()}
var _lanes: Array = []
var _active_index := 0
var _draft_value := 0.0
var _draft_mode := MODE_PERCENT
var _pad: Control


func _ready() -> void:
	var numeral := UITokens.dossier_font("numeral")
	_value_label.add_theme_font_override("font", numeral)
	_unit_label.add_theme_font_override("font", numeral)
	MoneyDisplay.apply_icon(_money_icon, 24)
	_shade.gui_input.connect(_on_shade_input)
	_close.pressed.connect(close_sheet)
	for i in range(_lane_buttons.size()):
		_lane_buttons[i].pressed.connect(_select_lane.bind(i))
	_mode_percent.pressed.connect(_set_mode.bind(MODE_PERCENT))
	_mode_absolute.pressed.connect(_set_mode.bind(MODE_ABSOLUTE))
	for i in range(_preset_buttons.size()):
		_preset_buttons[i].pressed.connect(_on_preset_pressed.bind(i))
	_minus_5.pressed.connect(_step.bind(-5))
	_minus_1.pressed.connect(_step.bind(-1))
	_plus_1.pressed.connect(_step.bind(1))
	_plus_5.pressed.connect(_step.bind(5))
	_keypad_btn.pressed.connect(_open_keypad)
	_reset_btn.pressed.connect(_on_reset_pressed)
	_confirm_btn.pressed.connect(_on_confirm_pressed)


func open_for_card(title_text: String, lanes: Array, initial_index: int = 0) -> void:
	if lanes.is_empty():
		return
	_title.text = title_text
	_lanes = lanes.duplicate(true)
	_active_index = clampi(initial_index, 0, _lanes.size() - 1)
	_load_active_lane()
	visible = true
	move_to_front()
	if is_inside_tree():
		grab_focus()


func close_sheet() -> void:
	visible = false


func _select_lane(index: int) -> void:
	if index < 0 or index >= _lanes.size() or index == _active_index:
		return
	_commit_current_if_dirty()
	_active_index = index
	_load_active_lane()


func _load_active_lane() -> void:
	var lane: Dictionary = _lanes[_active_index]
	_draft_mode = int(lane.get("mode", MODE_PERCENT))
	var raw := String(lane.get("value_text", "0")).strip_edges()
	_draft_value = raw.to_float() if (raw.is_valid_int() or raw.is_valid_float()) else 0.0
	_refresh_ui()


func _set_mode(mode: int) -> void:
	if mode == _draft_mode:
		return
	_draft_mode = mode
	_draft_value = 0.0
	_refresh_ui()


func _on_preset_pressed(index: int) -> void:
	var presets := ABSOLUTE_PRESETS if _draft_mode == MODE_ABSOLUTE else PERCENT_PRESETS
	if index >= 0 and index < presets.size():
		_draft_value = float(presets[index])
		_refresh_ui()


func _step(delta: int) -> void:
	var min_v := -100000.0 if _draft_mode == MODE_ABSOLUTE else -1000.0
	var max_v := 100000.0 if _draft_mode == MODE_ABSOLUTE else 100.0
	_draft_value = clampf(_draft_value + float(delta), min_v, max_v)
	_refresh_ui()


func _refresh_ui() -> void:
	if _lanes.is_empty():
		return
	_lane_row.visible = _lanes.size() > 1
	for i in range(_lane_buttons.size()):
		var btn := _lane_buttons[i]
		btn.visible = i < _lanes.size()
		if not btn.visible:
			continue
		var entry: Dictionary = _lanes[i]
		var shown_val := _format_num(_draft_value) if i == _active_index \
			else String(entry.get("value_text", "0"))
		var shown_mode := _draft_mode if i == _active_index else int(entry.get("mode", MODE_PERCENT))
		var unit := "" if shown_mode == MODE_ABSOLUTE else "%"
		btn.text = "%s %s%s" % [String(entry.get("label", "")), shown_val, unit]
		btn.theme_type_variation = &"PKPrimaryButton" if i == _active_index else &"PKIconButton"
	var lane: Dictionary = _lanes[_active_index]
	var absolute := _draft_mode == MODE_ABSOLUTE
	_kind_caption.text = String(lane.get("label", "税率"))
	_value_label.text = _format_num(_draft_value)
	_unit_label.text = "" if absolute else "%"
	_unit_label.visible = not absolute
	_money_icon.visible = absolute
	_hint_label.text = String(lane.get("hint", ""))
	_hint_label.visible = not _hint_label.text.is_empty() and not absolute
	_mode_percent.theme_type_variation = &"PKPrimaryButton" if not absolute else &"PKIconButton"
	_mode_absolute.theme_type_variation = &"PKPrimaryButton" if absolute else &"PKIconButton"
	var presets := ABSOLUTE_PRESETS if absolute else PERCENT_PRESETS
	for i in range(_preset_buttons.size()):
		var pbtn := _preset_buttons[i]
		var val: int = presets[i]
		pbtn.text = ("%d" % val) if absolute else ("%d%%" % val)
		var matched := is_equal_approx(_draft_value, float(val))
		pbtn.theme_type_variation = &"PKPrimaryButton" if matched else &"PKIconButton"
	_reset_btn.visible = bool(lane.get("can_reset", false))


func _commit_current_if_dirty() -> void:
	if _lanes.is_empty():
		return
	var lane: Dictionary = _lanes[_active_index]
	var text := _format_num(_draft_value)
	var old_text := String(lane.get("value_text", "0")).strip_edges()
	var old_mode := int(lane.get("mode", MODE_PERCENT))
	if text == old_text and _draft_mode == old_mode:
		return
	lane["value_text"] = text
	lane["mode"] = _draft_mode
	lane["can_reset"] = true
	_lanes[_active_index] = lane
	var commit: Callable = lane.get("commit", Callable())
	if commit.is_valid():
		commit.call(text, _draft_mode)


func _on_confirm_pressed() -> void:
	if not _lanes.is_empty():
		var lane: Dictionary = _lanes[_active_index]
		var text := _format_num(_draft_value)
		lane["value_text"] = text
		lane["mode"] = _draft_mode
		_lanes[_active_index] = lane
		var commit: Callable = lane.get("commit", Callable())
		if commit.is_valid():
			commit.call(text, _draft_mode)
	close_sheet()


func _on_reset_pressed() -> void:
	if _lanes.is_empty():
		return
	var lane: Dictionary = _lanes[_active_index]
	var reset_cb: Callable = lane.get("reset", Callable())
	if reset_cb.is_valid():
		reset_cb.call()
	close_sheet()


func _open_keypad() -> void:
	var pad := _ensure_pad()
	if pad == null or pad.is_open():
		return
	if not pad.submitted.is_connected(_on_pad_submitted):
		pad.submitted.connect(_on_pad_submitted)
		pad.dismissed.connect(_release_pad)
	var lane: Dictionary = _lanes[_active_index]
	pad.open({
		"title": "%s · %s" % [_title.text, String(lane.get("label", "税率"))],
		"suffix": "" if _draft_mode == MODE_ABSOLUTE else "%",
		"value": _format_num(_draft_value),
		"hint": String(lane.get("hint", "")),
		"mode": _draft_mode,
		"show_modes": true,
		"allow_negative": true,
	})


func _on_pad_submitted(text: String, mode: int) -> void:
	_release_pad()
	_draft_mode = mode
	if text.is_valid_int() or text.is_valid_float():
		_draft_value = text.to_float()
	_refresh_ui()


func _release_pad() -> void:
	if is_instance_valid(_pad):
		if _pad.submitted.is_connected(_on_pad_submitted):
			_pad.submitted.disconnect(_on_pad_submitted)
		if _pad.dismissed.is_connected(_release_pad):
			_pad.dismissed.disconnect(_release_pad)


func _ensure_pad() -> Control:
	var layer := get_parent()
	if layer == null:
		return null
	var existing := layer.get_node_or_null("TouchNumberPad") as Control
	if existing != null:
		_pad = existing
		return existing
	var inst := TouchNumberPad.instantiate() as Control
	inst.name = "TouchNumberPad"
	layer.add_child(inst)
	_pad = inst
	return inst


func _on_shade_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		close_sheet()
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_sheet()
		get_viewport().set_input_as_handled()


static func _format_num(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return "%d" % int(roundf(value))
	return ("%.2f" % value).trim_suffix("0").trim_suffix(".")
