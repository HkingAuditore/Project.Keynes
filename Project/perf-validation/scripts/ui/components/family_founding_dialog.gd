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
var _has_custom_safe_area := false
var _safe_area := Rect2()
var _cards: Array[FamilyFoundingCard] = []
var _card_tweens: Array[Tween] = []


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
	if _locate_button != null:
		_locate_button.pressed.connect(_on_locate_pressed)
	if _collapse_button != null:
		_collapse_button.pressed.connect(toggle_collapsed)
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
	var cell_tag := "地块 #%d · " % _cell_index if _cell_index >= 0 else ""
	var pop_detail := "人口达到 %d（当前 %d）" % [population, cell_pop] \
		if cell_pop > population else "人口达到 %d" % population
	if _archive_surface != null:
		_archive_surface.configure_header("%s · 望族兴起" % settlement,
			"地方志 · %s%s · 择一扶持" % [cell_tag, pop_detail], &"family.house")
	if _queue_badge != null and _queue_label != null:
		_queue_badge.visible = remaining > 0
		_queue_label.text = "另有 %d 处待决" % remaining
	if _locate_button != null:
		_locate_button.visible = true
		_locate_button.text = "定位：%s (#%d)" % [settlement, _cell_index] \
			if _cell_index >= 0 and not settlement.begins_with("地块") \
			else ("定位：%s" % settlement)
		_locate_button.tooltip_text = "将镜头对准事发地块，并在右侧打开地块档案（查看地理、资源与经济）"
	if _prompt != null:
		_prompt.text = "%s人口已达 %d，三户人家都有意立族。选择一户扶持，其余两户将不再出现。%s（可在右侧地块档案查看本地地理与经济详情，或点击右上角「收起看图」审视地图）" % [
			settlement, population,
			"（另有 %d 处待选）" % remaining if remaining > 0 else ""]
	_status.text = ""
	_status.visible = false
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	var candidates: Array = offer.get("candidates", [])
	for index in _cards.size():
		var candidate: Dictionary = candidates[index] if index < candidates.size() else {}
		_cards[index].set_candidate(candidate)
	_collapsed = false
	_apply_collapsed_visuals(false)
	_update_columns()
	visible = true
	move_to_front()
	if _archive_surface != null:
		UIAnimation.refresh_rest_position(_archive_surface)
		UIAnimation.fade_slide_in(_archive_surface, Vector2(0.0, 14.0), UITokens.ANIM_MED)
	_animate_cards_staggered()
	_grab_first_card_focus()


func _animate_cards_staggered() -> void:
	for tween in _card_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_card_tweens.clear()
	for index in _cards.size():
		var card := _cards[index]
		if card == null:
			continue
		card.modulate.a = 0.0
		var tween := card.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		if index > 0:
			tween.tween_interval(float(index) * 0.045)
		tween.tween_property(card, "modulate:a", 1.0, 0.16)
		_card_tweens.append(tween)


func _grab_first_card_focus() -> void:
	for card in _cards:
		if not card.candidate_empty():
			card.choose_button().grab_focus()
			break


func toggle_collapsed() -> void:
	set_collapsed(not _collapsed, true)


func set_collapsed(collapsed: bool, animate: bool = true) -> void:
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	_apply_collapsed_visuals(animate)
	_update_columns()
	if not _collapsed:
		_grab_first_card_focus()
	collapsed_changed.emit(_collapsed)


func is_collapsed() -> bool:
	return _collapsed


func _apply_collapsed_visuals(animate: bool) -> void:
	if _body != null:
		_body.visible = not _collapsed
	if _rule != null:
		_rule.visible = not _collapsed
	if _collapse_button != null:
		_collapse_button.text = "展开择族 ▾" if _collapsed else "收起看图 ▴"
		_collapse_button.tooltip_text = "展开候选家族卡片以完成抉择" if _collapsed \
			else "暂时收起卡片，无遮挡查看地图与右侧地块档案"
	if animate and _archive_surface != null and is_inside_tree():
		UIAnimation.crossfade(_archive_surface, UITokens.ANIM_FAST)


func _on_locate_pressed() -> void:
	locate_cell_requested.emit(_cell_index)


func _on_card_pressed(index: int) -> void:
	if index < 0 or index >= _cards.size() or _cards[index].candidate_empty():
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
	var max_width := maxf(safe.size.x - 16.0, 320.0)
	var panel_width := clampf(max_width, 320.0, 1020.0)
	if _collapsed:
		var collapsed_w := clampf(panel_width, 320.0, 760.0)
		var collapsed_h := 66.0
		var col_x := safe.position.x + maxf((safe.size.x - collapsed_w) * 0.5, 6.0)
		var col_y := safe.position.y + 6.0
		_archive_surface.position = Vector2(roundf(col_x), roundf(col_y))
		_archive_surface.size = Vector2(roundf(collapsed_w), roundf(collapsed_h))
	else:
		var max_height := maxf(safe.size.y - 16.0, 320.0)
		var panel_height := clampf(max_height, 360.0, 620.0)
		var pos_x := safe.position.x + maxf((safe.size.x - panel_width) * 0.5, 6.0)
		var pos_y := safe.position.y + maxf((safe.size.y - panel_height) * 0.5, 6.0)
		_archive_surface.position = Vector2(roundf(pos_x), roundf(pos_y))
		_archive_surface.size = Vector2(roundf(panel_width), roundf(panel_height))
		if _cards_scroll != null:
			_cards_scroll.custom_minimum_size.y = clampf(panel_height - 170.0, 200.0, 440.0)
	UIAnimation.refresh_rest_position(_archive_surface)
	_grid.columns = 3 if panel_width >= 700.0 else 2 if panel_width >= 480.0 else 1
	_setup_focus_neighbors()
	_archive_surface.set_compact(panel_width < 860.0)


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
	_status.visible = not message.is_empty()
	_status.modulate = UITokens.ARCHIVE_INK_MUTED


func show_error(message: String) -> void:
	for card in _cards:
		card.choose_button().disabled = card.candidate_empty()
	_status.text = "扶持未完成：%s" % message if not message.is_empty() \
		else "扶持未完成，请重试。"
	_status.visible = true
	_status.modulate = UITokens.RISK


func close_offer() -> void:
	visible = false
	_collapsed = false
	_offer_id = 0
	_generation = 0
	_cell_index = -1
	_status.text = ""
	_status.visible = false


func is_offer_open() -> bool:
	return visible


func current_offer_id() -> int:
	return _offer_id


func current_cell_index() -> int:
	return _cell_index
