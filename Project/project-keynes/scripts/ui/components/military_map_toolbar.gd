extends Control
class_name MilitaryMapToolbar

## Compact map-reading palette for military layers.  It owns no simulation
## state: each toggle only changes presentation visibility on MilitaryMapLayers.

const BUTTON_SCENE := preload("res://scenes/ui/map_overlay_icon_button.tscn")
const BUTTON_SIZE := Vector2(48.0, 48.0)
const ITEMS := [
	{"id": &"armies", "icon": &"military.banner", "title": "部队", "hint": "显示己方与已发现的部队"},
	{"id": &"front", "icon": &"military.war.front", "title": "战线", "hint": "显示交战接触边"},
	{"id": &"battle", "icon": &"military.war.battle", "title": "交战", "hint": "显示正在发生的战斗"},
	{"id": &"occupation", "icon": &"military.war.score", "title": "占领", "hint": "显示军事控制区域"},
	{"id": &"area", "icon": &"military.plan.barracks", "title": "控制区", "hint": "显示选中部队的区域任务"},
	{"id": &"convoy", "icon": &"military.ledger.convoy", "title": "车队", "hint": "显示军需运输路线"},
	{"id": &"route", "icon": &"action.pin", "title": "行军", "hint": "显示选中部队的行军路线"},
]

signal layer_toggled(layer_id: StringName, enabled: bool)

var _buttons: Dictionary = {}
var _enabled := {}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_PASS
	for item in ITEMS:
		var button := BUTTON_SCENE.instantiate() as Button
		button.name = String(item.id).capitalize()
		button.custom_minimum_size = BUTTON_SIZE
		button.focus_mode = Control.FOCUS_NONE # map gesture overlay boundary
		button.tooltip_text = "%s\n%s" % [String(item.title), String(item.hint)]
		IconButton.apply(button, item.icon, 32, button.tooltip_text, true, true)
		button.pressed.connect(_on_pressed.bind(StringName(item.id), button))
		$Panel/Margin/Column.add_child(button)
		_buttons[item.id] = button
		_enabled[item.id] = true


func set_available(available: bool) -> void:
	visible = available


func set_layer_visibility(layer_id: StringName, enabled: bool) -> void:
	if not _buttons.has(layer_id):
		return
	_enabled[layer_id] = enabled
	(_buttons[layer_id] as Button).set_pressed_no_signal(enabled)


func layer_visibility() -> Dictionary:
	return _enabled.duplicate()


func _on_pressed(layer_id: StringName, button: Button) -> void:
	var enabled := button.button_pressed
	_enabled[layer_id] = enabled
	layer_toggled.emit(layer_id, enabled)
