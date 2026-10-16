extends Control
class_name FamilyFoundingDialog

## Forced 1-of-3 pick shown when a player-owned cell reaches a population
## milestone. Only the chosen house is founded; the other two never appear.
## Floating dossier layout leaves the right-hand InspectorPanel and map camera
## interactive so the player can inspect geography, resources, and economy
## before choosing.

signal choice_requested(offer_id: int, generation: int, choice_index: int)
signal locate_cell_requested(cell_index: int)
signal collapsed_changed(collapsed: bool)
signal inspector_close_requested()

@onready var _collapsed_entry: Button = %CollapsedEntry
@onready var _grid: GridContainer = %CardGrid
@onready var _cards_scroll: ScrollContainer = %CardsScroll
@onready var _status: Label = %Status
@onready var _archive_surface: ArchivalSurface = get_node_or_null("ArchiveSurface") as ArchivalSurface
@onready var _frame: PanelContainer = get_node_or_null("ArchiveSurface/Frame") as PanelContainer
@onready var _rule: CanvasItem = get_node_or_null("ArchiveSurface/Frame/Margin/Column/Rule") as CanvasItem
@onready var _body: Control = get_node_or_null("ArchiveSurface/Frame/Margin/Column/Body") as Control
@onready var _prompt: Label = get_node_or_null(
		"ArchiveSurface/Frame/Margin/Column/Body/Prompt/Margin/Text") as Label
@onready var _queue_badge: PanelContainer = get_node_or_null("%QueueBadge") as PanelContainer
@onready var _queue_label: Label = get_node_or_null("%QueueLabel") as Label
@onready var _locate_button: Button = get_node_or_null("%LocateButton") as Button
@onready var _collapse_button: Button = get_node_or_null("%CollapseButton") as Button

var _offer_id := 0
var _generation := 0
var _cell_index := -1
var _settlement_name := "本地"
var _collapsed := false
var _manual_collapsed := false
var _inspector_obscures := false
var _expanded_index := -1
var _details_view_revision := 0
var _pending := false
var _offer_open := false
var _close_revision := 0
var _layout_rect := Rect2()
var _has_custom_safe_area := false
var _safe_area := Rect2()
var _cards: Array[FamilyFoundingCard] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_floating_frame_style()
	if _archive_surface != null:
		_archive_surface.configure_header("望族兴起", "地方志 · 择一扶持", &"family.house")
	for child in _grid.get_children():
		if child is FamilyFoundingCard:
			_cards.append(child as FamilyFoundingCard)
	for index in _cards.size():
		_cards[index].selected.connect(_on_card_pressed.bind(index))
		_cards[index].details_requested.connect(_on_details_requested.bind(index))
	if _locate_button != null:
		_locate_button.pressed.connect(_on_locate_pressed)
	if _collapse_button != null:
		_collapse_button.pressed.connect(toggle_collapsed)
	_collapsed_entry.add_theme_color_override("font_focus_color", UITokens.ARCHIVE_INK)
	_collapsed_entry.pressed.connect(func() -> void:
		_manual_collapsed = false
		if _inspector_obscures:
			inspector_close_requested.emit()
		else:
			set_collapsed(false))
	get_viewport().size_changed.connect(_update_columns)
	_update_columns()


func _apply_floating_frame_style() -> void:
	if _frame == null:
		return
	var base := _frame.get_theme_stylebox("panel", &"PKArchivePanel")
	if base is StyleBoxTexture:
		var textured := (base as StyleBoxTexture).duplicate() as StyleBoxTexture
		textured.modulate_color = Color(1.0, 0.99, 0.96, 0.99)
		_frame.add_theme_stylebox_override("panel", textured)


func set_safe_area(rect: Rect2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	_has_custom_safe_area = true
	_safe_area = rect
	_update_columns()


func present_offer(offer: Dictionary) -> void:
	if _offer_open and _offer_id == int(offer.get("offer_id", 0)) and _generation == int(offer.get("generation", 0)):
		return
	_close_revision += 1
	_offer_open = true
	_pending = false
	_expanded_index = -1
	_details_view_revision += 1
	UIAnimation.cancel(_archive_surface)
	_offer_id = int(offer.get("offer_id", 0))
	_generation = int(offer.get("generation", 0))
	_cell_index = int(offer.get("cell", -1))
	var settlement := String(offer.get("settlement_name", "")).strip_edges()
	if settlement.is_empty():
		settlement = "地块 #%d" % _cell_index if _cell_index >= 0 else "本地"
	_settlement_name = settlement
	var population := int(offer.get("milestone_population", 0))
	var cell_pop := int(offer.get("cell_population", population))
	var remaining := int(offer.get("queue_remaining", 0))
	var split := String(offer.get("kind", "FOUNDING")) == "SPLIT"
	if _archive_surface != null:
		_archive_surface.configure_header("%s · %s" % [settlement, "分支立族" if split else "望族兴起"],
			"同宗分支 · 择定家风" if split else
			"人口 %s · 择一扶持" % UITokens.format_compact_number_cn(float(cell_pop), 0), &"family.house")
	if _queue_badge != null and _queue_label != null:
		_queue_badge.visible = remaining > 0
		_queue_label.text = "另有 %d 处待决" % remaining
	if _locate_button != null:
		_locate_button.text = "定位城市"
		_locate_button.tooltip_text = "定位%s，并查看右侧地块档案" % settlement
	if _prompt != null:
		if split:
			_prompt.text = "%s在%s的分支已具备独立条件。保留原姓氏，择定一套家风与效果；本地整支族人、产业和名人统一转入新家族，原家族在其他城市继续存在。" % [
				String(offer.get("source_family_name", "原家族")), settlement]
		else:
			_prompt.text = "%s人口已达 %s。择一户扶持，其余两户将不再出现。" % [
				settlement, UITokens.format_compact_number_cn(float(population), 0)]
	_collapsed_entry.text = "%s · %s    展开" % [settlement, "待定家风" if split else "待择族"]
	_status.text = ""
	_status.visible = false
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	var candidates: Array = offer.get("candidates", [])
	for index in _cards.size():
		var candidate: Dictionary = candidates[index] if index < candidates.size() else {}
		_cards[index].set_candidate(candidate)
	_manual_collapsed = false
	_collapsed = _inspector_obscures
	_cards_scroll.scroll_vertical = 0
	_apply_collapsed_visuals(false)
	_update_columns()
	visible = true
	move_to_front()
	if _archive_surface != null:
		UIAnimation.refresh_rest_position(_archive_surface)
		if not _collapsed:
			UIAnimation.fade_slide_in(_archive_surface, Vector2(-24.0, 0.0), UITokens.ANIM_MED)
	_animate_cards_staggered()
	_grab_first_card_focus()


func _animate_cards_staggered() -> void:
	for card in _cards:
		UIAnimation.cancel(card)
	if not _collapsed:
		UIAnimation.stagger_children_in(_grid, 0.025, 3, UITokens.ANIM_FAST)


func _on_details_requested(index: int) -> void:
	if not _offer_open or index < 0 or index >= _cards.size() or _cards[index].candidate_empty():
		return
	_expanded_index = -1 if _expanded_index == index else index
	_details_view_revision += 1
	for card_index in _cards.size():
		_cards[card_index].set_details_expanded(card_index == _expanded_index)
	# Replacing an expanded predecessor shifts this card upward; keep its summary visible.
	call_deferred("_reveal_card", index, _details_view_revision)


func _reveal_card(index: int, revision: int) -> void:
	await get_tree().create_timer(UITokens.ANIM_DISCLOSURE).timeout
	if _offer_open and not _collapsed and revision == _details_view_revision:
		_cards_scroll.ensure_control_visible(_cards[index].details_button())


func _grab_first_card_focus() -> void:
	for card in _cards:
		if not card.candidate_empty():
			card.details_button().grab_focus()
			break


func toggle_collapsed() -> void:
	set_collapsed(not _manual_collapsed)


func set_collapsed(collapsed: bool, animate: bool = true) -> void:
	_manual_collapsed = collapsed
	_sync_collapsed(animate)


func set_inspector_obscures(obscures: bool) -> void:
	if _inspector_obscures == obscures:
		return
	_inspector_obscures = obscures
	_sync_collapsed(true)


func _sync_collapsed(animate: bool) -> void:
	var collapsed := _manual_collapsed or _inspector_obscures
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	UIAnimation.cancel(_archive_surface)
	_archive_surface.position = _layout_rect.position.round()
	UIAnimation.refresh_rest_position(_archive_surface)
	_apply_collapsed_visuals(animate)
	_update_columns()
	if _offer_open:
		if _collapsed:
			_collapsed_entry.grab_focus()
		else:
			_grab_first_card_focus()
	collapsed_changed.emit(_collapsed)


func is_collapsed() -> bool:
	return _collapsed


func _apply_collapsed_visuals(animate: bool) -> void:
	_archive_surface.visible = not _collapsed
	_collapsed_entry.visible = _collapsed
	if _body != null:
		_body.visible = not _collapsed
	if _rule != null:
		_rule.visible = not _collapsed
	_collapsed_entry.tooltip_text = "返回家族扶持（关闭当前大档案）" if _inspector_obscures else "展开候选家族，继续扶持抉择"
	if animate and _offer_open:
		UIAnimation.crossfade(_collapsed_entry if _collapsed else _archive_surface, UITokens.ANIM_FAST)


func _on_locate_pressed() -> void:
	locate_cell_requested.emit(_cell_index)


func _on_card_pressed(index: int) -> void:
	if not _offer_open or _pending or index < 0 or index >= _cards.size() or _cards[index].candidate_empty():
		return
	_set_pending("正在提交扶持选择……")
	choice_requested.emit(_offer_id, _generation, index)


func _resolved_safe_area() -> Rect2:
	var viewport_size := get_viewport_rect().size
	if _has_custom_safe_area and _safe_area.size.x > 0.0 and _safe_area.size.y > 0.0:
		return _safe_area
	var left := 24.0
	var top := 52.0
	var bottom := 48.0
	var right := 24.0
	return Rect2(
		Vector2(left, top),
		Vector2(
			maxf(viewport_size.x - left - right, 320.0),
			maxf(viewport_size.y - top - bottom, 320.0)
		)
	)


func _update_columns() -> void:
	if _grid == null or _archive_surface == null:
		return
	var safe := _resolved_safe_area()
	var wide := get_viewport_rect().size.x >= 1440.0
	var preferred_width := UITokens.FAMILY_FOUNDING_WIDE_WIDTH if wide else UITokens.FAMILY_FOUNDING_WIDTH
	var available := maxf(safe.size.x - UITokens.SPACE_LG, 1.0)
	var width := minf(preferred_width, available)
	if available >= 400.0 + UITokens.FAMILY_FOUNDING_MAP_GAP:
		width = minf(width, available - UITokens.FAMILY_FOUNDING_MAP_GAP)
	var rect := Rect2(safe.position + Vector2(UITokens.SPACE_SM, UITokens.SPACE_SM),
		Vector2(width, maxf(safe.size.y - UITokens.SPACE_LG, 1.0)))
	if rect != _layout_rect:
		UIAnimation.cancel(_archive_surface)
		_archive_surface.position = rect.position.round()
		_archive_surface.size = rect.size.round()
		_layout_rect = rect
		UIAnimation.refresh_rest_position(_archive_surface)
	_collapsed_entry.position = rect.position.round()
	_collapsed_entry.size = Vector2(UITokens.FAMILY_FOUNDING_COLLAPSED_WIDTH, 44.0)
	_cards_scroll.custom_minimum_size.y = 0.0
	_grid.columns = 1
	_archive_surface.set_compact(true)
	_setup_focus_neighbors()


func _setup_focus_neighbors() -> void:
	var buttons: Array[Button] = [_locate_button, _collapse_button]
	for card in _cards:
		if not card.candidate_empty():
			buttons.append(card.details_button())
			buttons.append(card.choose_button())
	for index in buttons.size():
		var button := buttons[index]
		button.focus_mode = Control.FOCUS_ALL
		var previous := buttons[(index + buttons.size() - 1) % buttons.size()]
		var next := buttons[(index + 1) % buttons.size()]
		button.focus_previous = button.get_path_to(previous)
		button.focus_next = button.get_path_to(next)
		button.focus_neighbor_top = button.focus_previous
		button.focus_neighbor_bottom = button.focus_next
		button.focus_neighbor_left = button.focus_previous
		button.focus_neighbor_right = button.focus_next


func _set_pending(message: String) -> void:
	_pending = true
	for card in _cards:
		card.choose_button().disabled = true
	_status.text = message
	_status.visible = not message.is_empty()
	_status.modulate = UITokens.ARCHIVE_INK_MUTED


func show_error(message: String) -> void:
	_pending = false
	for card in _cards:
		card.choose_button().disabled = card.candidate_empty()
	_status.text = "扶持未完成：%s" % message if not message.is_empty() \
		else "扶持未完成，请重试。"
	_status.visible = true
	_status.modulate = UITokens.RISK


func close_offer() -> void:
	if not _offer_open:
		return
	_offer_open = false
	_pending = false
	_close_revision += 1
	var revision := _close_revision
	_offer_id = 0
	_generation = 0
	_cell_index = -1
	_status.text = ""
	_status.visible = false
	for card in _cards:
		UIAnimation.cancel(card)
	if _collapsed:
		UIAnimation.cancel(_collapsed_entry)
		visible = false
	else:
		UIAnimation.fade_slide_out(_archive_surface, Vector2(-24.0, 0.0), UITokens.ANIM_FAST)
		await get_tree().create_timer(UITokens.ANIM_FAST).timeout
		if revision == _close_revision and not _offer_open:
			visible = false


func is_offer_open() -> bool:
	return _offer_open


func current_offer_id() -> int:
	return _offer_id


func current_cell_index() -> int:
	return _cell_index


func map_reserved_right_edge() -> float:
	return _layout_rect.end.x if _offer_open and not _collapsed else 0.0
