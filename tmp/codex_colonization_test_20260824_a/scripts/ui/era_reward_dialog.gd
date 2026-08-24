extends Control
class_name EraRewardDialog

signal choice_requested(offer_generation: int, choice_index: int)

const ICON_MAP := {
	"wheat": "economy.crop",
	"industry": "economy.building",
	"flask": "economy.building.science",
	"route": "economy.building.transport",
	"landmark": "technology.milestone",
	"people": "family.house",
	"shield": "country.politics",
	"book": "country.technology",
	"gear": "economy.building.factory",
}
const CATEGORY_MAP := {
	"wheat": "粮食方案", "industry": "产业方案", "flask": "科研方案",
	"route": "交通方案", "landmark": "国家方案", "people": "社会方案",
	"shield": "组织方案", "book": "知识方案", "gear": "动员方案",
}

@onready var _grid: GridContainer = %CardGrid
@onready var _status: Label = %Status
@onready var _archive_surface: ArchivalSurface = get_node_or_null("ArchiveSurface") as ArchivalSurface
@onready var _prompt: Label = get_node_or_null(
		"ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text") as Label

var _offer_generation := 0
var _choices: Array[EraRewardChoice] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _archive_surface != null:
		_archive_surface.configure_header("时代奖励", "时代晋升记录 · 选择一项正式方案",
			&"country.technology")
	for child in _grid.get_children():
		if child is EraRewardChoice:
			_choices.append(child as EraRewardChoice)
	for index in _choices.size():
		_choices[index].selected.connect(_on_choice_pressed.bind(index))
	get_viewport().size_changed.connect(_update_columns)
	_update_columns()

func present_offer(offer: Dictionary) -> void:
	_offer_generation = int(offer.get("offer_generation", 0))
	var era_title := String(offer.get("era_title", "时代"))
	if _archive_surface != null:
		_archive_surface.configure_header(era_title, "时代晋升记录 · 选择一项正式方案",
			&"country.technology")
	if _prompt != null:
		_prompt.text = "从下列三项 %s 方案中择一，选择后将提交本次晋升的正式效果。" % era_title
	_status.text = ""
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	var alternatives: Array = offer.get("alternatives", [])
	for index in _choices.size():
		var option: Dictionary = alternatives[index] if index < alternatives.size() else {}
		_choices[index].set_option(_presentation_option(option))
	_update_columns()
	visible = true
	move_to_front()
	UIAnimation.fade_slide_in(self, Vector2(0.0, 18.0), 0.18)
	if not _choices.is_empty():
		_choices[0].get_node("Margin/Column/Choose").grab_focus()

func _presentation_option(option: Dictionary) -> Dictionary:
	if option.is_empty():
		return {}
	var raw_icon := String(option.get("icon_id", "system.unknown"))
	var mapped_icon := String(ICON_MAP.get(raw_icon, raw_icon))
	var presented := option.duplicate(true)
	presented["icon_key"] = mapped_icon
	presented["category"] = String(CATEGORY_MAP.get(raw_icon, "时代方案"))
	return presented

func _on_choice_pressed(index: int) -> void:
	if index < 0 or index >= _choices.size() or _choices[index].option_empty():
		return
	_set_pending("正在提交奖励并等待所有领域确认……")
	choice_requested.emit(_offer_generation, index)

func _update_columns() -> void:
	if _grid == null:
		return
	var width := get_viewport_rect().size.x
	_grid.columns = 3 if width >= 1280.0 else 2 if width >= 860.0 else 1
	_setup_focus_neighbors()
	if _archive_surface != null:
		_archive_surface.set_compact(width < 1280.0)

func _setup_focus_neighbors() -> void:
	var columns := maxi(1, _grid.columns)
	for index in _choices.size():
		var button := _choices[index].get_node("Margin/Column/Choose") as Button
		button.focus_mode = Control.FOCUS_ALL
		var row := int(index / columns)
		var column := index % columns
		button.focus_neighbor_left = NodePath("")
		button.focus_neighbor_right = NodePath("")
		button.focus_neighbor_top = NodePath("")
		button.focus_neighbor_bottom = NodePath("")
		if column > 0:
			button.focus_neighbor_left = _choices[index - 1].get_node(
				"Margin/Column/Choose").get_path()
		if column + 1 < columns and index + 1 < _choices.size():
			button.focus_neighbor_right = _choices[index + 1].get_node(
				"Margin/Column/Choose").get_path()
		if row > 0 and index - columns >= 0:
			button.focus_neighbor_top = _choices[index - columns].get_node(
				"Margin/Column/Choose").get_path()
		if index + columns < _choices.size():
			button.focus_neighbor_bottom = _choices[index + columns].get_node(
				"Margin/Column/Choose").get_path()

func _set_pending(message: String) -> void:
	for choice in _choices:
		var button := choice.get_node("Margin/Column/Choose") as Button
		button.disabled = true
	_status.text = message
	_status.modulate = UITokens.ARCHIVE_INK_MUTED

func show_error(message: String) -> void:
	_set_pending("奖励提交未完成：%s\n游戏保持暂停，请稍后重试。" % message)
	_status.modulate = UITokens.RISK

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
