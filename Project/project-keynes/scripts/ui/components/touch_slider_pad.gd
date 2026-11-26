extends Control

## 触摸端大量程滑条 + 数字键盘联动挂件：点击滑条数值读数即可弹出 TouchNumberPad 精确输入。

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const PAD_SCENE_PATH := "res://scenes/ui/touch_number_pad.tscn"
const DRAG_TOLERANCE := 12.0

var _slider_ref: WeakRef
var _config: Dictionary = {}
var _pressing := false
var _press_pos := Vector2.ZERO
var _pad_ref: WeakRef


static func attach_to(readout: Control, slider: Range, config: Dictionary = {}) -> Control:
	if readout == null or slider == null or not TouchUI.is_touch():
		return null
	var existing := readout.get_node_or_null("TouchSliderPad") as Control
	if existing != null:
		existing.call("configure", slider, config)
		return existing
	var script := load("res://scripts/ui/components/touch_slider_pad.gd") as GDScript
	var helper := script.new() as Control
	helper.configure(slider, config)
	helper.name = "TouchSliderPad"
	helper.mouse_filter = Control.MOUSE_FILTER_STOP
	helper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	readout.mouse_filter = Control.MOUSE_FILTER_PASS
	readout.add_child(helper)
	return helper


func configure(slider: Range, config: Dictionary) -> void:
	_slider_ref = weakref(slider)
	_config = config.duplicate(false)


func _exit_tree() -> void:
	_release_pad()
	_config.clear()
	_slider_ref = null


func _slider() -> Range:
	return _slider_ref.get_ref() as Range if _slider_ref != null else null


func _gui_input(event: InputEvent) -> void:
	var slider := _slider()
	if not TouchUI.is_touch() or slider == null or not is_instance_valid(slider):
		return
	if slider is HSlider and not (slider as HSlider).editable:
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_pressing = true
		_press_pos = mb.position
		accept_event()
		return
	if not _pressing:
		return
	_pressing = false
	if mb.position.distance_to(_press_pos) <= DRAG_TOLERANCE:
		_open_pad(slider)
	accept_event()


func _open_pad(slider: Range) -> void:
	var pad := _ensure_pad()
	if pad == null or pad.is_open():
		return
	if not pad.submitted.is_connected(_on_submitted):
		pad.submitted.connect(_on_submitted)
		pad.dismissed.connect(_release_pad)
	var scale := float(_config.get("display_scale", 1.0))
	var current_val := int(roundf(slider.value * scale))
	var min_val := int(roundf(slider.min_value * scale))
	var max_val := int(roundf(slider.max_value * scale))
	var default_hint := "范围 %d ~ %d" % [min_val, max_val]
	pad.open({
		"title": _resolve_str(_config.get("title", "精确输入数值")),
		"suffix": _resolve_str(_config.get("suffix", "")),
		"value": str(current_val),
		"hint": _resolve_str(_config.get("hint", default_hint)),
		"mode": 0,
		"show_modes": false,
		"allow_negative": slider.min_value < 0.0,
	})


func _on_submitted(text: String, _mode: int) -> void:
	_release_pad()
	var slider := _slider()
	if slider == null or not is_instance_valid(slider):
		return
	if not (text.is_valid_int() or text.is_valid_float()):
		return
	var scale := maxf(float(_config.get("display_scale", 1.0)), 0.0001)
	var clamped := clampf(text.to_float() / scale, slider.min_value, slider.max_value)
	slider.value = clamped
	var commit: Callable = _config.get("commit", Callable())
	if commit.is_valid():
		commit.call(clamped)


func _release_pad() -> void:
	var pad: Control = (_pad_ref.get_ref() as Control) if _pad_ref != null else null
	if pad == null or not is_instance_valid(pad):
		pad = _find_pad()
	if pad == null:
		return
	if pad.submitted.is_connected(_on_submitted):
		pad.submitted.disconnect(_on_submitted)
	if pad.dismissed.is_connected(_release_pad):
		pad.dismissed.disconnect(_release_pad)


func _ensure_pad() -> Control:
	var pad := _find_pad()
	if pad != null:
		return pad
	var layer := _find_layer()
	if layer == null:
		return null
	var scene := load(PAD_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	pad = scene.instantiate()
	pad.name = "TouchNumberPad"
	layer.add_child(pad)
	_pad_ref = weakref(pad)
	return pad


func _find_pad() -> Control:
	var layer := _find_layer()
	return layer.get_node_or_null("TouchNumberPad") as Control if layer != null else null


func _find_layer() -> Node:
	var node: Node = self
	while node != null and not (node is CanvasLayer):
		node = node.get_parent()
	if node != null:
		return node
	return get_tree().root if is_inside_tree() else null


static func _resolve_str(v: Variant) -> String:
	if v is Callable and (v as Callable).is_valid():
		return String((v as Callable).call())
	return String(v)
