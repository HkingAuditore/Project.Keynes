extends Control

## 触摸档下盖在 SpinBox 上的一层透明命中区：点一下数值 → 打开游戏内数字键盘。
##
## 为什么是「盖一层」而不是改版式：税率行的 30 设计像素高是 PC 版式的一部分，
## 抬高会立刻变成玩家说的「按钮离奇地高、布局和 PC 对不上」。这一层是输入框的
## 全矩形子节点，不参与 HBox 布局、不改任何 custom_minimum_size，视觉与桌面逐像素一致；
## 它只做两件事：把落在数字上的手指接住，以及顺手关掉系统软键盘。
##
## 只盖 LineEdit、不盖右侧的上下箭头：那两个箭头在触摸档把它 step 设成 1，
## 仍然是可以点的「笨办法」，盖住就成了看得见点不动的死控件。数字那一整块
## （88~120 × 30）才是主要入口，进去之后是 92 设计像素高的按键。
##
## 不写 class_name，由宿主 preload。

const TouchNumberPad = preload("res://scripts/ui/components/touch_number_pad.gd")

## 手指移动超过这个距离（设计像素）就认为是在滑动列表，不弹键盘。
const DRAG_TOLERANCE := 12.0

## 宿主保留的配置：title / hint / commit / mode / show_modes / allow_negative
## commit 的签名是 func(text: String, mode: int) —— 口径跟数值一起交回去，
## 宿主不必先落一次「归零」命令再落真正的税率。
var _config: Dictionary = {}
var _spin: SpinBox
## 共享键盘的引用：卡片重建/面板关掉时，别指望还能从树上按名字找回来。
var _pad: Control
var _press_position := Vector2.ZERO
var _pressed := false


## 挂在 spin 身上并接管它的点击。config.commit(text) 必须是宿主原有的提交入口，
## 这样「解析—钳位—次日生效」的链路完全不变。
func attach(spin: SpinBox, config: Dictionary) -> void:
	_spin = spin
	_config = config.duplicate(true)
	name = "TouchValueField"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var line := spin.get_line_edit()
	var host: Control = line if line != null else spin
	if get_parent() == null:
		host.add_child(self)
	if line != null:
		# 兜底：万一有别的路径把焦点给了输入框，也不要弹系统键盘盖住整屏。
		line.virtual_keyboard_enabled = false
		line.gui_input.connect(_on_line_gui_input)


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		_press_position = button.position
		_pressed = true
		accept_event()
		return
	if not _pressed:
		return
	_pressed = false
	# 手指从这一格起手滑列表时不要顺手弹出键盘：位移超过容差就只当滚动。
	if button.position.distance_to(_press_position) <= DRAG_TOLERANCE:
		_open_pad()
	accept_event()


func _on_line_gui_input(event: InputEvent) -> void:
	# 桌面档不会挂这一层；这里只在触摸档存在，用来吃掉漏到 LineEdit 的点击。
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	_open_pad()
	accept_event()


func _open_pad() -> void:
	if _spin == null or not is_instance_valid(_spin) or not _spin.editable:
		return
	var pad := _ensure_pad()
	if pad == null or pad.is_open():
		return
	if not pad.submitted.is_connected(_on_pad_submitted):
		pad.submitted.connect(_on_pad_submitted)
		pad.dismissed.connect(_on_pad_dismissed)
	pad.open({
		"title": _resolved(_config.get("title", "调整数值")),
		"suffix": _current_suffix(),
		"value": _current_text(),
		"hint": _resolved(_config.get("hint", "")),
		"mode": _current_mode(),
		"show_modes": bool(_config.get("show_modes", true)),
		"allow_negative": bool(_config.get("allow_negative", true)),
	})


func _on_pad_submitted(text: String, mode: int) -> void:
	_release_pad()
	var commit: Callable = _config.get("commit", Callable())
	if commit.is_valid():
		commit.call(text, mode)


func _on_pad_dismissed() -> void:
	_release_pad()


func _release_pad() -> void:
	var pad := _pad if is_instance_valid(_pad) else _existing_pad()
	if pad == null:
		return
	if pad.submitted.is_connected(_on_pad_submitted):
		pad.submitted.disconnect(_on_pad_submitted)
	if pad.dismissed.is_connected(_on_pad_dismissed):
		pad.dismissed.disconnect(_on_pad_dismissed)


## 一个 UI CanvasLayer 只留一份键盘：二十条税率行各自造一个会白占几十个节点。
func _ensure_pad() -> Control:
	var pad := _existing_pad()
	if pad != null:
		return pad
	var layer := _layer()
	if layer == null:
		return null
	pad = TouchNumberPad.new()
	pad.name = "TouchNumberPad"
	layer.add_child(pad)
	_pad = pad
	return pad


func _existing_pad() -> Control:
	var layer := _layer()
	if layer == null:
		return null
	return layer.get_node_or_null("TouchNumberPad") as Control


func _layer() -> Node:
	var node: Node = self
	while node != null:
		if node is CanvasLayer:
			return node
		node = node.get_parent()
	if not is_inside_tree():
		return null
	return get_tree().root


## 口径：宿主给 Callable 就现取（下拉框被改过），否则按输入框有没有 "%" 后缀猜。
func _current_mode() -> int:
	var mode: Variant = _config.get("mode", 0)
	if mode is Callable:
		return int((mode as Callable).call())
	if mode is int or mode is float:
		return int(mode)
	return 1 if _current_suffix().is_empty() else 0


func _current_suffix() -> String:
	if _spin == null:
		return ""
	return String(_spin.suffix)


## 输入框里的文本带单位（「12 %」「¥30」），键盘只认数字，先把记号摘掉。
func _current_text() -> String:
	if _spin == null:
		return ""
	var line := _spin.get_line_edit()
	var raw := line.text if line != null else ""
	var cleaned := MoneyDisplay.strip_unit(raw).replace("%", "").replace(" ", "")
	return cleaned.strip_edges()


## title / hint 都可以给 Callable：税率、继承值这些在挂接之后还会变。
func _resolved(value: Variant) -> String:
	if value is Callable:
		return String((value as Callable).call())
	return String(value)
