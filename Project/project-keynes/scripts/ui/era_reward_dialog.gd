extends Control
class_name EraRewardDialog

signal choice_requested(offer_generation: int, choice_index: int)

@onready var _title: Label = %Title
@onready var _grid: GridContainer = %CardGrid
@onready var _status: Label = %Status

var _offer_generation := 0
var _buttons: Array[Button] = []
var _titles: Array[Label] = []
var _descriptions: Array[Label] = []
var _targets: Array[Label] = []
var _reasons: Array[Label] = []
var _icons: Array[Label] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for index in range(3):
		var card := _grid.get_node("Card%d" % index)
		_icons.append(card.get_node("Margin/Column/Icon"))
		_titles.append(card.get_node("Margin/Column/Title"))
		_descriptions.append(card.get_node("Margin/Column/Description"))
		_targets.append(card.get_node("Margin/Column/Target"))
		_reasons.append(card.get_node("Margin/Column/Reason"))
		var button: Button = card.get_node("Margin/Column/Choose")
		button.pressed.connect(_on_choice_pressed.bind(index))
		_buttons.append(button)
	get_viewport().size_changed.connect(_update_columns)
	_update_columns()

func present_offer(offer: Dictionary) -> void:
	_offer_generation = int(offer.get("offer_generation", 0))
	_title.text = "%s提升：选择时代奖励" % String(offer.get("era_title", "时代"))
	_status.text = ""
	var alternatives: Array = offer.get("alternatives", [])
	for index in range(3):
		var option: Dictionary = alternatives[index] if index < alternatives.size() else {}
		_icons[index].text = String(option.get("icon_id", "reward")).to_upper()
		_titles[index].text = String(option.get("title", "奖励"))
		_descriptions[index].text = String(option.get("description", ""))
		_targets[index].text = "目标：%s" % String(option.get(
			"target_summary", "玩家国家"))
		var reasons: PackedStringArray = option.get("reasons", PackedStringArray())
		_reasons[index].text = "适配：%s" % "；".join(reasons) \
			if not reasons.is_empty() else ""
		_buttons[index].disabled = option.is_empty()
	_update_columns()
	visible = true
	move_to_front()
	if not _buttons.is_empty():
		_buttons[0].grab_focus()

func _on_choice_pressed(index: int) -> void:
	_set_pending("正在提交奖励并等待所有领域确认……")
	choice_requested.emit(_offer_generation, index)

func _update_columns() -> void:
	_grid.columns = 1 if get_viewport_rect().size.x < 980 else 3

func _set_pending(message: String) -> void:
	for button in _buttons:
		button.disabled = true
	_status.text = message
	_status.modulate = Color(0.82, 0.84, 0.9)

func show_error(message: String) -> void:
	_set_pending("奖励提交未完成：%s\n游戏保持暂停，请稍后重试。" % message)
	_status.modulate = Color(1.0, 0.48, 0.42)

func show_pending() -> void:
	_set_pending("正在提交奖励并等待所有领域确认……")

func close_offer() -> void:
	visible = false
	_offer_generation = 0
	_status.text = ""

func is_offer_open() -> bool:
	return visible

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventMouseButton:
		accept_event()
