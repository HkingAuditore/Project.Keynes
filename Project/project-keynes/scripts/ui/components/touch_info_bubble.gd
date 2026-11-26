extends Control

## 触摸端轻量揭示气泡：用于展示桌面端依赖 hover/tooltip 才能看到的禁用原因、指标解释与快捷跳转。

signal action_triggered()

@onready var _backdrop: Control = %Backdrop
@onready var _card: PanelContainer = %Card
@onready var _title: Label = %Title
@onready var _body: Label = %Body
@onready var _action: Button = %ActionButton

var _action_callback: Callable = Callable()


func _ready() -> void:
	_backdrop.gui_input.connect(_on_backdrop_input)
	_action.pressed.connect(_on_action_pressed)


func open_near(anchor_rect: Rect2, config: Dictionary) -> void:
	var title_text := String(config.get("title", "")).strip_edges()
	var body_text := String(config.get("body", "")).strip_edges()
	var action_text := String(config.get("action_text", "")).strip_edges()
	if title_text.is_empty() and body_text.is_empty():
		return
	_action_callback = config.get("action", Callable())
	_title.text = title_text
	_title.visible = not title_text.is_empty()
	_body.text = body_text
	_body.visible = not body_text.is_empty()
	_action.text = action_text
	_action.visible = not action_text.is_empty() and _action_callback.is_valid()
	visible = true
	_card.reset_size()
	call_deferred("_place_near", anchor_rect)


func dismiss() -> void:
	visible = false
	_action_callback = Callable()


func _place_near(anchor_rect: Rect2) -> void:
	if not visible or not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	var card_size := _card.get_combined_minimum_size()
	card_size.x = clampf(maxf(card_size.x, _card.size.x), 240.0, minf(420.0, vp.x - 24.0))
	_card.size = Vector2(card_size.x, 0.0)
	card_size = _card.get_combined_minimum_size()
	var x := clampf(anchor_rect.position.x + (anchor_rect.size.x - card_size.x) * 0.5,
		12.0, maxf(12.0, vp.x - card_size.x - 12.0))
	var y := anchor_rect.end.y + 8.0
	if y + card_size.y > vp.y - 12.0:
		y = maxf(12.0, anchor_rect.position.y - card_size.y - 8.0)
	_card.position = Vector2(x, y)


func _on_backdrop_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		dismiss()
		accept_event()


func _on_action_pressed() -> void:
	var cb := _action_callback
	dismiss()
	if cb.is_valid():
		cb.call()
	action_triggered.emit()
