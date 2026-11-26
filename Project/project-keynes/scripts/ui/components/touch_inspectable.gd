extends Control

## 触摸端揭示器挂件：为禁用按钮或纯 tooltip 控件提供轻点原因气泡，桌面档全程零介入。

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const BUBBLE_SCENE_PATH := "res://scenes/ui/touch_info_bubble.tscn"
const DRAG_TOLERANCE := 14.0

var _target_ref: WeakRef
var _config: Dictionary = {}
var _pressing := false
var _press_pos := Vector2.ZERO


static func bind_disabled_reason(button: BaseButton, title: String = "",
		reason_getter: Callable = Callable()) -> Control:
	if button == null or not TouchUI.is_touch():
		return null
	var existing := button.get_node_or_null("TouchInspectable") as Control
	if existing != null:
		return existing
	var script := load("res://scripts/ui/components/touch_inspectable.gd") as GDScript
	var helper := script.new() as Control
	helper.attach(button, {
		"only_when_disabled": true,
		"title": title,
		"body": reason_getter,
	})
	return helper


func attach(target: Control, config: Dictionary) -> void:
	_target_ref = weakref(target)
	_config = config.duplicate(false)
	name = "TouchInspectable"
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if get_parent() == null:
		target.add_child(self)


func _exit_tree() -> void:
	_config.clear()
	_target_ref = null


func _gui_input(event: InputEvent) -> void:
	var target: Control = _target_ref.get_ref() as Control if _target_ref != null else null
	if not TouchUI.is_touch() or target == null or not is_instance_valid(target):
		return
	if bool(_config.get("only_when_disabled", false)):
		if not (target is BaseButton) or not (target as BaseButton).disabled:
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
		_show_bubble(target)
	accept_event()


func _show_bubble(target: Control) -> void:
	var body := _resolve_text(_config.get("body", Callable()))
	if body.is_empty() and target != null:
		body = target.tooltip_text.strip_edges()
	if body.is_empty():
		return
	var title := _resolve_text(_config.get("title", ""))
	var bubble := _ensure_bubble_for(self)
	if bubble != null:
		bubble.open_near(target.get_global_rect(), {
			"title": title,
			"body": body,
			"action_text": _resolve_text(_config.get("action_text", "")),
			"action": _config.get("action", Callable()),
		})


static func show_for_control(target: Control, config: Dictionary) -> void:
	if target == null or not target.is_inside_tree():
		return
	var bubble := _ensure_bubble_for(target)
	if bubble != null:
		bubble.open_near(target.get_global_rect(), config)


static func _ensure_bubble_for(node: Node) -> Control:
	var layer: Node = node
	while layer != null and not (layer is CanvasLayer):
		layer = layer.get_parent()
	if layer == null and node.is_inside_tree():
		layer = node.get_tree().root
	if layer == null:
		return null
	var existing := layer.get_node_or_null("TouchInfoBubble") as Control
	if existing != null:
		return existing
	var scene := load(BUBBLE_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate() as Control
	inst.name = "TouchInfoBubble"
	layer.add_child(inst)
	return inst


static func _resolve_text(raw: Variant) -> String:
	if raw is Callable and (raw as Callable).is_valid():
		return String((raw as Callable).call()).strip_edges()
	return String(raw).strip_edges()
