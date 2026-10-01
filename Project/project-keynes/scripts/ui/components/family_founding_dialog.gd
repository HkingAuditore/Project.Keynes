extends Control
class_name FamilyFoundingDialog

## Forced 1-of-3 pick shown when a player-owned cell reaches a population
## milestone. Only the chosen house is founded; the other two never appear.

signal choice_requested(offer_id: int, generation: int, choice_index: int)

@onready var _grid: GridContainer = %CardGrid
@onready var _status: Label = %Status
@onready var _archive_surface: ArchivalSurface = get_node_or_null("ArchiveSurface") as ArchivalSurface
@onready var _prompt: Label = get_node_or_null(
		"ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text") as Label

var _offer_id := 0
var _generation := 0
var _cards: Array[FamilyFoundingCard] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _archive_surface != null:
		_archive_surface.configure_header("望族兴起", "地方志 · 择一扶持", &"family.house")
	for child in _grid.get_children():
		if child is FamilyFoundingCard:
			_cards.append(child as FamilyFoundingCard)
	for index in _cards.size():
		_cards[index].selected.connect(_on_card_pressed.bind(index))
	get_viewport().size_changed.connect(_update_columns)
	_update_columns()

func present_offer(offer: Dictionary) -> void:
	_offer_id = int(offer.get("offer_id", 0))
	_generation = int(offer.get("generation", 0))
	var settlement := String(offer.get("settlement_name", "")).strip_edges()
	if settlement.is_empty():
		settlement = "本地"
	var population := int(offer.get("milestone_population", 0))
	if _archive_surface != null:
		_archive_surface.configure_header("%s · 望族兴起" % settlement,
			"地方志 · 人口达到 %d · 择一扶持" % population, &"family.house")
	if _prompt != null:
		var remaining := int(offer.get("queue_remaining", 0))
		_prompt.text = "%s人口已达 %d，三户人家都有意立族。选择一户扶持，其余两户将不再出现。%s" % [
			settlement, population,
			"（另有 %d 处待选）" % remaining if remaining > 0 else ""]
	_status.text = ""
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	var candidates: Array = offer.get("candidates", [])
	for index in _cards.size():
		var candidate: Dictionary = candidates[index] if index < candidates.size() else {}
		_cards[index].set_candidate(candidate)
	_update_columns()
	visible = true
	move_to_front()
	UIAnimation.fade_slide_in(self, Vector2(0.0, 18.0), 0.18)
	for card in _cards:
		if not card.candidate_empty():
			card.choose_button().grab_focus()
			break

func _on_card_pressed(index: int) -> void:
	if index < 0 or index >= _cards.size() or _cards[index].candidate_empty():
		return
	_set_pending("正在提交扶持选择……")
	choice_requested.emit(_offer_id, _generation, index)

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
	for index in _cards.size():
		var button := _cards[index].choose_button()
		button.focus_mode = Control.FOCUS_ALL
		var row := int(index / columns)
		var column := index % columns
		button.focus_neighbor_left = NodePath("")
		button.focus_neighbor_right = NodePath("")
		button.focus_neighbor_top = NodePath("")
		button.focus_neighbor_bottom = NodePath("")
		if column > 0:
			button.focus_neighbor_left = _cards[index - 1].choose_button().get_path()
		if column + 1 < columns and index + 1 < _cards.size():
			button.focus_neighbor_right = _cards[index + 1].choose_button().get_path()
		if row > 0 and index - columns >= 0:
			button.focus_neighbor_top = _cards[index - columns].choose_button().get_path()
		if index + columns < _cards.size():
			button.focus_neighbor_bottom = _cards[index + columns].choose_button().get_path()

func _set_pending(message: String) -> void:
	for card in _cards:
		card.choose_button().disabled = true
	_status.text = message
	_status.modulate = UITokens.ARCHIVE_INK_MUTED

func show_error(message: String) -> void:
	for card in _cards:
		card.choose_button().disabled = card.candidate_empty()
	_status.text = "扶持未完成：%s" % message if not message.is_empty() \
		else "扶持未完成，请重试。"
	_status.modulate = UITokens.RISK

func close_offer() -> void:
	visible = false
	_offer_id = 0
	_generation = 0
	_status.text = ""

func is_offer_open() -> bool:
	return visible

func current_offer_id() -> int:
	return _offer_id

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventMouseButton:
		accept_event()
