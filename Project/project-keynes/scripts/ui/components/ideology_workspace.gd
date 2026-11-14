extends Control
class_name IdeologyWorkspace

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const IdeologyWorkspacePresentationScript = preload("res://scripts/ui/components/ideology_workspace_presentation.gd")
var _presentation_component = IdeologyWorkspacePresentationScript.new()

# Papercut deck-building view over the native ideology authority. Facade-only:
# every mutation is a PlayerController command, and rows are rebuilt only when
# the compact native snapshot signature changes. Animation state never feeds
# back into gameplay state.

## "This card acts on these cells — show them on the map." Emitted only with a
## non-empty list, so a listener never has to distinguish "no cells" from
## "please clear". The workspace cannot paint anything itself: the map lives
## outside this panel, and the panel is full-bleed, so the receiver is expected
## to close it first.
signal target_cells_requested(cells: PackedInt32Array)

const Q16_ONE := 65536.0
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CardScript = preload("res://scripts/ui/components/ideology_card.gd")
const NicheScript = preload("res://scripts/ui/components/ideology_slot_niche.gd")
const LevelProgressScript = preload(
	"res://scripts/ui/components/ideology_level_progress.gd")
const LevelMeterScript = preload(
	"res://scripts/ui/components/ideology_level_meter.gd")
const PointScrollScript = preload("res://scripts/ui/components/ideology_point_scroll.gd")
const IdeologyEffectReportScript = preload("res://scripts/ideology/ideology_effect_report.gd")
const HINT_HOLD_MSEC := 4500
## Height of the offer tray chrome (title, actions, margins) around the cards.
const STAGE_CHROME_HEIGHT := 196.0
const STAGE_CHROME_HEIGHT_COMPACT := 148.0
const STAGE_CARD_MIN_HEIGHT := 140.0
const STAGE_CARD_MAX_HEIGHT := 410.0
const STAGE_OUTER_INSET := 12.0
const COMPACT_TITLE_STYLE := &"PKIdeologyStageTitle"
const COLLECTION_COLUMN_MIN_WIDTH := 560.0
const COLLECTION_COLUMN_MIN_WIDTH_COMPACT := 390.0
const SLOT_COLUMN_MIN_WIDTH := 360.0
const SLOT_COLUMN_MIN_WIDTH_COMPACT := 300.0
const SORT_LABELS := ["收录顺序", "稀有度", "流派", "境界"]
## Motion follows the shared game setting (main menu / pause menu) so this
## panel never grows a second switch. Read it on demand; it is a dict lookup.
static func motion_reduced() -> bool:
	return UIAnimation.reduced_motion()

var _facade = null
var _player_controller = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _presentation: Dictionary = {}
var _live_explain: Dictionary = {}
var _live_by_id := {}
# Per-card effect-instance totals, see IdeologyEffectReport.
var _effect_summary: Dictionary = {}
var _metadata := {}
var _states := {}
var _signature: Array = []
var _explain_signature: Array = []
var _resonance_signature: PackedInt32Array = PackedInt32Array()
var _points_signature := ""
var _pending_promotion_id := -1
var _compact := false
var _tab_school := ""
var _sort_mode := 0
var _draw_phase := ""
var _revealed_generation := 0
var _chosen_generation := -1
var _dismissed_generation := -1
var _offer_anim_busy := false
var _hint_hold_until := 0
var _active_resonances := {}
var _hover_niche: Control = null
var _hover_id := -1
var _collection_entries := {}
var _entry_intro_played := false
var _indexed_snapshot_valid := false
var _indexed_idea_ids := PackedInt32Array()
var _indexed_understanding := PackedInt64Array()
var _indexed_levels := PackedInt32Array()
var _indexed_locations := PackedInt32Array()
var _indexed_pending := PackedByteArray()
var _effect_report_day := -1
var _effect_report_context: Array = []

var _root: VBoxContainer
var _draw_stack: DrawStack
var _stage_card_applied := Vector2.ZERO
var _stage_available_height := 0.0
var _point_scroll: Control
var _hint: Label
var _offer_button: Button
var _offer_layer: Control
var _offer: PanelContainer
var _offer_title: Label
var _offer_hint: Label
var _choice_0: Control
var _choice_1: Control
var _choice_2: Control
var _reroll_button: Button
var _dismiss_button: Button
var _offer_column: VBoxContainer
var _offer_body: MarginContainer
var _offer_cards: HBoxContainer
var _offer_actions: HBoxContainer
var _offer_header: VBoxContainer
var _offer_footer: VBoxContainer
var _slot_counts: Label
var _ideology_slots: VBoxContainer
var _spirit_slots: VBoxContainer
var _ideology_section_header: PanelContainer
var _spirit_section_header: PanelContainer
var _spirit_alcove: PanelContainer
var _spirit_inset: MarginContainer
var _resonance_bar: HFlowContainer
var _resonance_views := {}
var _tabs: TabBar
var _sort: OptionButton
var _body: HBoxContainer
var _slot_column: VBoxContainer
var _collection_column: VBoxContainer
var _deck_table: PanelContainer
var _deck_heading: HBoxContainer
var _deck_scroll: ScrollContainer
var _deck_column: VBoxContainer
var _resonance_panel: PanelContainer
var _collection_margin: MarginContainer
var _collection_heading: VBoxContainer
var _collection_heading_surface: PanelContainer
var _collection_heading_top: HBoxContainer
var _collection_title: Label
var _collection_tabs_scroll: ScrollContainer
var _top_bar: PanelContainer
var _top_title: Label
var _collection_drop: PanelContainer
var _collection: HFlowContainer
var _scroll: ScrollContainer
var _empty: PanelContainer
var _empty_icon: IconBadge
var _empty_title: Label
var _empty_detail: Label
var _empty_insights: InsightList
var _fx: Control
var _promotion_dialog: ConfirmationDialog
var _promotion_layer: Control
var _promotion_sheet: PanelContainer
var _promotion_title: Label
var _promotion_copy: Label
var _promotion_confirm: Button
var _promotion_cancel: Button
var _ledger_popup: PopupPanel
var _modal_canvas: CanvasLayer
var _detail_layer: Control
var _detail_sheet: VBoxContainer
var _detail_body_host: VBoxContainer
var _detail_close: Button
var _detail_ideology_id := -1
var _detail_is_offer := false


func _ready() -> void:
	_bind_nodes()
	TouchUI.watch(_offer_layer)
	TouchUI.watch(_detail_layer)
	TouchUI.watch(self)
	if _empty_icon != null:
		_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	call_deferred("_play_workspace_intro")
	call_deferred("_focus_initial_action")


func _bind_nodes() -> void:
	if _offer_button != null:
		return
	_root = get_node_or_null("Root") as VBoxContainer
	_top_bar = get_node_or_null("Root/TopBar") as PanelContainer
	_body = get_node_or_null("Root/Body") as HBoxContainer
	_slot_column = get_node_or_null("Root/Body/SlotColumn") as VBoxContainer
	_collection_column = get_node_or_null("Root/Body/CollectionColumn") as VBoxContainer
	_deck_table = get_node_or_null("Root/Body/SlotColumn/DeckTable") as PanelContainer
	_deck_scroll = _deck_table.get_node_or_null("DeckBody/DeckScroll") as ScrollContainer \
		if _deck_table != null else null
	_deck_column = _deck_scroll.get_node_or_null("DeckColumn") as VBoxContainer \
		if _deck_scroll != null else null
	_resonance_panel = get_node_or_null(
		"Root/Body/SlotColumn/ResonancePanel") as PanelContainer
	_collection_heading = get_node_or_null("Root/Body/CollectionColumn/CollectionHeading") as VBoxContainer
	_point_scroll = %PointScroll
	_hint = %Hint
	_offer_button = %OpenOffer
	_offer_layer = %OfferLayer
	# Candidates use viewport space even when the country page is short.
	var modal_canvas := CanvasLayer.new()
	modal_canvas.name = "CandidateModal"
	modal_canvas.layer = 30
	_modal_canvas = modal_canvas
	add_child(modal_canvas)
	visibility_changed.connect(func() -> void:
		modal_canvas.visible = is_visible_in_tree()
		if not is_visible_in_tree():
			_close_detail_modal()
		else:
			call_deferred("_focus_initial_action"))
	_offer_layer.reparent(modal_canvas)
	_offer_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_offer_layer_insets()
	_offer = %Offer
	_offer_title = %OfferTitle
	_choice_0 = %Choice0
	_choice_1 = %Choice1
	_choice_2 = %Choice2
	_reroll_button = %Reroll
	_dismiss_button = %Dismiss
	_slot_counts = %SlotCounts
	_ideology_slots = %IdeologySlots
	_spirit_slots = %SpiritSlots
	_resonance_bar = %ResonanceBar
	_tabs = %SchoolTabs
	_sort = %SortMode
	_collection_drop = %CollectionDrop
	_collection_margin = _collection_drop.get_node_or_null(
		"CollectionMargin") as MarginContainer
	_collection = %Collection
	_scroll = %CollectionScroll
	_empty = %EmptyState
	_empty_icon = %EmptyIcon
	_empty_title = %EmptyTitle
	_empty_detail = %EmptyDetail
	_empty_insights = %EmptyInsights
	_fx = %Fx
	_promotion_dialog = %PromotionDialog
	_ledger_popup = %LedgerPopup
	_build_promotion_overlay()
	_build_detail_overlay()
	_build_dynamic_parts()


## The stock ConfirmationDialog belongs to the debug theme and flashes a
## rectangular grey window over the paper workspace. Build the promotion
## confirmation once from the same paper material as the cards, then only
## replace its text when a different ideology is requested. This keeps the
## modal cheap to open and preserves the native command/ACK path underneath.
func _build_detail_overlay() -> void:
	if _detail_layer != null:
		return
	_detail_layer = Control.new()
	_detail_layer.name = "DetailOverlay"
	_detail_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_detail_layer.visible = false
	_detail_layer.theme = preload("res://assets/themes/player_session_theme.tres")
	var host: Node = _modal_canvas if _modal_canvas != null else self
	host.add_child(_detail_layer)
	var veil := ColorRect.new()
	veil.name = "DetailVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = Color(0.07, 0.045, 0.025, 0.46)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed:
				_close_detail_modal()
				veil.accept_event())
	_detail_layer.add_child(veil)
	var center := CenterContainer.new()
	center.name = "DetailCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_layer.add_child(center)
	_detail_sheet = VBoxContainer.new()
	_detail_sheet.name = "DetailSheet"
	_detail_sheet.alignment = BoxContainer.ALIGNMENT_CENTER
	_detail_sheet.add_theme_constant_override("separation", 8)
	_detail_sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_detail_sheet)
	_detail_body_host = VBoxContainer.new()
	_detail_body_host.name = "DetailBodyHost"
	_detail_body_host.mouse_filter = Control.MOUSE_FILTER_STOP
	_detail_sheet.add_child(_detail_body_host)
	var actions := HBoxContainer.new()
	actions.name = "DetailActions"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.mouse_filter = Control.MOUSE_FILTER_STOP
	_detail_sheet.add_child(actions)
	_detail_close = Button.new()
	_detail_close.name = "DetailCloseButton"
	_detail_close.text = "关闭"
	_detail_close.custom_minimum_size = Vector2(132, maxf(38.0, TouchUI.min_units()))
	_detail_close.theme_type_variation = &"PKSealPrimaryButton"
	_detail_close.focus_mode = Control.FOCUS_ALL
	_detail_close.pressed.connect(_close_detail_modal)
	actions.add_child(_detail_close)
	_apply_offer_layer_insets()


func _fill_slots(host: VBoxContainer, kind: int, hosted: Array[int], capacity: int) -> void:
	IdeologyWorkspacePresentationScript._fill_slots(self, host, kind, hosted, capacity)


func _refresh_board_values(support_changed: bool,
		progress_ids: PackedInt32Array, pending_ids: PackedInt32Array,
		level_ids: PackedInt32Array, effect_ids: PackedInt32Array) -> void:
	IdeologyWorkspacePresentationScript._refresh_board_values(self, support_changed, progress_ids, pending_ids, level_ids, effect_ids)


static func _tier_less(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("min_count", 0)) < int(b.get("min_count", 0))


# --- drag and drop --------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _hover_niche != null:
		_hover_niche = null
		_hover_id = -1
		_update_resonance(null, -1)


func _unhandled_key_input(event: InputEvent) -> void:
	if _detail_layer != null and _detail_layer.visible \
			and event.is_action_pressed(&"ui_cancel"):
		_close_detail_modal()
		get_viewport().set_input_as_handled()
		return
	if _promotion_layer != null and _promotion_layer.visible \
			and event.is_action_pressed(&"ui_cancel"):
		_close_promotion_overlay()
		get_viewport().set_input_as_handled()
		return
	if _offer_layer != null and _offer_layer.is_visible_in_tree() \
			and event.is_action_pressed(&"ui_cancel"):
		if not _draw_waiting() and not _offer_anim_busy:
			_dismiss_offer()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if _offer_layer == null or not _offer_layer.is_visible_in_tree():
		return
	var backwards := event.is_action_pressed(&"ui_focus_prev")
	if not backwards and not event.is_action_pressed(&"ui_focus_next"):
		return
	var targets: Array[Control] = []
	for control in [_choice_0, _choice_1, _choice_2, _reroll_button, _dismiss_button]:
		if control.is_visible_in_tree() and not (control is Button and control.disabled):
			targets.append(control)
	if not targets.is_empty():
		var index := targets.find(get_viewport().gui_get_focus_owner())
		targets[posmod(index + (-1 if backwards else 1), targets.size())].grab_focus()
	get_viewport().set_input_as_handled()


func _on_slot_command(op: String, ideology_id: int) -> void:
	_command(op, ideology_id)


func _on_card_activated(ideology_id: int) -> void:
	# Keyboard / gamepad accept: same intent as the primary action button.
	var location := int((_states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if location == 0:
		_command("equip", ideology_id)
	elif location == 1:
		_command("unequip", ideology_id)


func _on_tab_changed(tab: int) -> void:
	_tab_school = "" if tab <= 0 else String(ArtScript.SCHOOL_ORDER[tab - 1])
	if _snapshot.is_empty():
		return
	_signature = []
	_rebuild_board()
	_signature = _board_signature(
		_snapshot.get("known_ids", PackedInt32Array()))


func _on_sort_selected(index: int) -> void:
	_sort_mode = index
	if _snapshot.is_empty():
		return
	_signature = []
	_rebuild_board()
	_signature = _board_signature(
		_snapshot.get("known_ids", PackedInt32Array()))


# --- commands -------------------------------------------------------------

func _open_offer() -> void:
	var generation := int(_snapshot.get("offer_generation", 0))
	if bool(_snapshot.get("offer_active", false)) and generation == _dismissed_generation:
		_dismissed_generation = -1
		_render_top()
		_rebuild_offer()
		return
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	if not bool(result.get("ok", false)):
		_show_result(result)


func _reroll_offer() -> void:
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_REROLL, {
			"offer_generation": int(_snapshot.get("offer_generation", 0)),
		})
	if bool(result.get("ok", false)):
		_render_draw_waiting()
	else:
		_show_result(result)


func _dismiss_offer() -> void:
	_dismissed_generation = int(_snapshot.get("offer_generation", 0))
	if _player_controller != null and _player_controller.has_method("dismiss_ideology_offer"):
		_player_controller.dismiss_ideology_offer()
	_render_top()
	_rebuild_offer()
	_offer_button.grab_focus()


func _command(kind: String, ideology_id: int) -> void:
	if _player_controller == null or ideology_id < 0:
		return
	var command_id := {
		"equip": PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		"unequip": PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		"promote": PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	}.get(kind, &"") as StringName
	var result: Dictionary = _player_controller.request_command(
		command_id, {"ideology_id": ideology_id})
	_show_result(result)


func _request_promotion(ideology_id: int) -> void:
	if _promotion_layer == null or ideology_id < 0:
		return
	_pending_promotion_id = ideology_id
	_promotion_copy.text = "将「%s」晋升为民族精神？" \
		% _display_name(_metadata.get(ideology_id, {}), ideology_id)
	_promotion_layer.visible = true
	_promotion_confirm.grab_focus()


func _confirm_promotion() -> void:
	if _pending_promotion_id < 0:
		return
	var ideology_id := _pending_promotion_id
	_pending_promotion_id = -1
	if _promotion_layer != null:
		_promotion_layer.visible = false
	_command("promote", ideology_id)


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	if id not in [
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER,
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE,
		PlayerControllerScript.COMMAND_IDEOLOGY_REROLL,
		PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	]:
		return
	if bool(result.get("ok", false)):
		_flash_hint("")
	else:
		var message := CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。"))))
		_flash_hint(message)
		_toast(message)


func _on_ideology_offer_ready(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	_draw_phase = "presenting"
	_snapshot = snapshot
	_presentation = CountryViewModel.present_ideology(_snapshot, _catalog)
	_index_states()
	_dismissed_generation = -1
	_hint_hold_until = 0
	_render_top()
	_rebuild_offer()


func _on_ideology_draw_state_changed(phase: String, detail: Dictionary) -> void:
	_draw_phase = phase
	var message := String(detail.get("message", ""))
	if not message.is_empty():
		_flash_hint(message)
		_toast(message)
	_render_top()
	_rebuild_offer()


func _show_result(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_flash_hint("明日生效")
	else:
		_flash_hint(CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。")))))
		if _compact:
			_toast(_hint.text)


func _flash_hint(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint.visible = not _compact and not text.is_empty()
	_hint_hold_until = Time.get_ticks_msec() + HINT_HOLD_MSEC


# --- offer stage ----------------------------------------------------------

func _choice(index: int) -> Control:
	return [_choice_0, _choice_1, _choice_2][index]


func _rebuild_offer() -> void:
	if _offer_anim_busy:
		return
	var active := bool(_snapshot.get("offer_active", false))
	var generation := int(_snapshot.get("offer_generation", 0))
	var waiting := _draw_waiting()
	var chosen := active and generation == _chosen_generation
	var dismissed := active and generation == _dismissed_generation and not waiting
	if (not active and not waiting) or chosen or dismissed:
		_set_stage_visible(false)
		_set_draw_stack(false)
		for index in 3:
			_choice(index).visible = false
		if not active:
			_chosen_generation = -1
		# The stage is closed: never leave the paper cover or a face-down card
		# armed for the next reveal.
		return
	_set_stage_visible(true)
	var ids: PackedInt32Array = _snapshot.get("offer_ids", PackedInt32Array())
	var fresh := active and generation > _revealed_generation and not waiting
	if waiting and not fresh:
		# Draw submitted; the one-day settlement has not published yet. Showing
		# three face-down frames here is what read as a placeholder image before
		# the reveal, so only the shuffled deck is on stage.
		_render_draw_waiting()
		return
	_set_draw_stack(false)
	_offer_title.text = "选择国策"
	for index in 3:
		var card := _choice(index)
		var show := index < ids.size()
		card.visible = show
		if show:
			var ideology_id := int(ids[index])
			var meta: Dictionary = _metadata.get(ideology_id, {})
			var view := CountryViewModel.present_ideology_card(meta, 0)
			card.call("set_card", {
				"ideology_id": ideology_id,
				"display_name": _display_name(meta, ideology_id),
				"school_id": String(meta.get("school_id", "")),
				"rarity": int(meta.get("rarity", 1)),
				"rarity_label": String(meta.get("rarity_label", "")),
				"effects": view.get("effect_lines", PackedStringArray()),
				"level": 0,
				"level_count": int(view.get("level_count", 3)),
				"level_label": String(view.get("level_label", "")),
				"tooltip": String(view.get("tooltip", "")),
				"detail_model": _detail_data(ideology_id, true),
			})
			_apply_offer_card_tilt(card, index, int(meta.get("rarity", 1)))
	var reroll_cost := String(_presentation.get("reroll_cost_text", ""))
	_reroll_button.text = "重抽 · %s" % reroll_cost
	_reroll_button.disabled = not bool(_presentation.get("can_reroll", false))
	_reroll_button.tooltip_text = "花费 %s 理念点重抽" % reroll_cost
	_dismiss_button.disabled = false
	if fresh:
		_revealed_generation = generation
		_play_reveal(ids.size())
	else:
		for index in 3:
			_choice(index).call("set_face_up", true)


func _render_draw_waiting() -> void:
	_offer_title.text = "正在抽取"
	_offer_hint.text = "正在整理候选国策…"
	for index in 3:
		var card := _choice(index)
		card.visible = false
		card.call("reset_motion")
	_reroll_button.disabled = true
	_dismiss_button.disabled = true
	_set_draw_stack(true)


func _apply_offer_card_tilt(card: Control, _index: int, _rarity: int) -> void:
	card.set("stage_rest_offset", Vector2.ZERO)
	card.set("stage_rest_rotation", 0.0)


func _set_draw_stack(show: bool) -> void:
	if _draw_stack == null:
		return
	# These are alternative views of one card-height area, never two VBox rows.
	_offer_cards.visible = not show
	_offer_actions.visible = not show
	if not show and _offer_hint != null:
		_offer_hint.text = "悬停查看详情 · 单击选定 · Esc 收起"
	if show:
		_draw_stack.set_card_size(_stage_card_size())
		if not _draw_stack.visible:
			_draw_stack.visible = true
			_draw_stack.play(not motion_reduced())
	else:
		_draw_stack.stop()
		_draw_stack.visible = false


## The offer tray is a modal layer over the workspace: a scrim plus the centred
## paper stage. Showing it fades in; hiding is instant so the closing beat of the
## choose animation is never covered by a lingering scrim.
func _set_stage_visible(show: bool) -> void:
	if _offer != null:
		_offer.visible = show
	if _offer_layer == null:
		return
	if not show:
		if _offer_layer.visible:
			_offer_layer.visible = false
			_offer_layer.modulate.a = 1.0
		return
	if _offer_layer.visible:
		return
	_offer_layer.visible = true
	if motion_reduced():
		_offer_layer.modulate.a = 1.0
		return
	_offer_layer.modulate.a = 0.0
	var tween := _offer_layer.create_tween()
	tween.tween_property(_offer_layer, "modulate:a", 1.0, UITokens.ANIM_FAST)


## Fully open the unroll mask and lift the torn paper. Used whenever the stage
## is shown without a reveal, so a previous cover can never linger.
func _play_reveal(count: int) -> void:
	if motion_reduced() or not is_visible_in_tree():
		for index in count:
			_choice(index).call("reset_motion")
			_choice(index).call("set_face_up", true)
		return
	_offer_anim_busy = true
	for index in count:
		var card := _choice(index)
		card.call("reset_motion")
		card.call("set_face_up", true)
		card.call("play_drop", index * 0.07, 16.0)
		if int(card.get("_rarity")) > 1:
			var sheen := create_tween()
			sheen.tween_interval(0.30 + index * 0.07)
			sheen.tween_callback(card.call.bind("play_gloss", 1))
	var tween := create_tween()
	tween.tween_interval(0.45 + maxf(0, count - 1) * 0.07)
	tween.tween_callback(_finish_offer_animation)


func _finish_offer_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		if _choice(index).visible:
			_choice(index).call("set_face_up", true)
	if is_visible_in_tree():
		_choice_0.grab_focus()
	_rebuild_offer()


func _on_choice_input(event: InputEvent, index: int) -> void:
	# Press moves keyboard/gamepad focus onto the card; the selection itself
	# arrives through `activated` on release.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_choice(index).grab_focus()


func _on_choice_activated(_ideology_id: int, index: int) -> void:
	_choose_offer(index)


func _on_choice_detail_requested(ideology_id: int) -> void:
	_open_detail_modal(ideology_id, true)


func _choose_offer(choice_index: int) -> void:
	if _player_controller == null or _offer_anim_busy:
		return
	var generation := int(_snapshot.get("offer_generation", 0))
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE, {
			"offer_generation": generation,
			"choice_index": choice_index,
		})
	_show_result(result)
	if not bool(result.get("ok", false)):
		return
	_flash_hint("")
	_chosen_generation = generation
	_play_choose(choice_index)


func _play_choose(choice_index: int) -> void:
	if motion_reduced() or not is_visible_in_tree():
		_rebuild_offer()
		return
	_offer_anim_busy = true
	for index in 3:
		if index != choice_index and _choice(index).visible:
			_choice(index).call("fold_away", 0.18)
	_choice(choice_index).call("stamp_punch")
	var tween := create_tween()
	tween.tween_interval(0.32)
	tween.tween_property(_offer_layer, "modulate:a", 0.0, 0.16)
	tween.tween_callback(_finish_choose_animation)


func _finish_choose_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		_choice(index).call("reset_motion")
	_rebuild_offer()
	if is_visible_in_tree():
		_offer_button.grab_focus()


func _toast(text: String) -> void:
	if _fx == null or text.is_empty():
		return
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PKPaperToast"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := ArtScript.label(text, 14, ArtScript.INK)
	panel.add_child(label)
	_fx.add_child(panel)
	panel.reset_size()
	panel.position = Vector2((_fx.size.x - panel.size.x) * 0.5, 84.0)
	if motion_reduced():
		get_tree().create_timer(2.4).timeout.connect(panel.queue_free)
		return
	panel.modulate.a = 0.0
	var tween := panel.create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	tween.parallel().tween_property(panel, "position:y", 72.0, 0.18)
	tween.tween_interval(2.2)
	tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	tween.tween_callback(panel.queue_free)


func _open_ledger() -> void:
	if _ledger_popup == null:
		return
	for child in _ledger_popup.get_children():
		_ledger_popup.remove_child(child)
		child.queue_free()
	_ledger_popup.add_child(PointScrollScript.build_ledger(_snapshot))
	_ledger_popup.popup_centered(Vector2i(420, 320))


# --- text helpers ---------------------------------------------------------

func _support_summary(live: Dictionary, direction: int) -> String:
	var action: String = ["推行", "撤回", "晋升"][clampi(direction, 0, 2)]
	var rows: Array = live.get("support", [])
	if direction < 0 or direction >= rows.size():
		return "%s支持条件待更新" % action
	var support: Dictionary = rows[direction]
	if not bool(support.get("available", false)):
		return "%s支持条件待结算" % action
	var result := "已满足" if bool(support.get("allowed", false)) else "未满足"
	var line := "%s支持条件%s · 评分 %s / 门槛 %s" % [action, result,
		_q16_signed(int(support.get("support_q16", 0))),
		_q16_signed(int(support.get("threshold_q16", 0)))]
	if int(support.get("blocking_class", -1)) >= 0:
		line += "（关键阶层未达到最低支持要求）"
	return line


func _support_tooltip(live: Dictionary, direction: int) -> String:
	var lines := PackedStringArray([_support_summary(live, direction),
		"支持评分由各阶层的影响力与对此操作的态度加权得出。推行、撤回、晋升分别判断。"])
	var class_ids: PackedStringArray = _catalog.get("political_class_ids", PackedStringArray())
	var names := {"general": "一般阶层", "farmer": "农民阶层",
		"worker": "工人阶层", "technology": "学者阶层"}
	for row in live.get("classes", []) as Array:
		var info := row as Dictionary
		var index := int(info.get("class_index", -1))
		var contributions: Array = info.get("contributions", [])
		var contribution := int(contributions[direction]) if direction >= 0 and direction < contributions.size() else 0
		var id := String(class_ids[index]) if index >= 0 and index < class_ids.size() else ""
		lines.append("%s · 加权贡献 %+.2f" % [String(names.get(id, "其他阶层")), float(contribution) / Q16_ONE])
	return "\n".join(lines)


func _display_name(metadata: Dictionary, ideology_id: int) -> String:
	var display := String(metadata.get("display_name", ""))
	if not display.is_empty():
		return display
	var name_key := String(metadata.get("name_key", ""))
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	var stable_id := String(metadata.get("id", ""))
	return stable_id if not stable_id.is_empty() else "理念 %d" % ideology_id


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)


func _q16_signed(value: int) -> String:
	return "%+.2f" % (float(value) / Q16_ONE)


func _show_shell(reason: String, loading: bool) -> void:
	_signature = []
	_explain_signature = []
	_points_signature = ""
	_effect_summary = {}
	_effect_report_context = []
	_effect_report_day = -1
	_resonance_signature = PackedInt32Array()
	_indexed_snapshot_valid = false
	_indexed_idea_ids = PackedInt32Array()
	_indexed_understanding = PackedInt64Array()
	_indexed_levels = PackedInt32Array()
	_indexed_locations = PackedInt32Array()
	_indexed_pending = PackedByteArray()
	_states.clear()
	_presentation = {}
	_snapshot = {}
	_offer_button.disabled = true
	_offer_button.text = "抽取"
	_hint.text = "载入中…" if loading and reason.is_empty() else (
		reason if not reason.is_empty() else "暂不可用")
	_hint.visible = true
	_set_stage_visible(false)
	_set_draw_stack(false)
	_point_scroll.call("set_points", 0, 65536, 0, false, true)
	_show_empty_state(true, {
		"empty_title": "载入中…" if loading else "暂不可用",
		"empty_detail": _hint.text,
	})


func _show_empty_state(visible_state: bool, presentation: Dictionary) -> void:
	if _empty == null:
		return
	_empty.visible = visible_state
	# The cabinet card and the collection panel compete for the same column.
	if _collection_drop != null:
		_collection_drop.visible = not visible_state
	if not visible_state:
		return
	_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	_empty_title.text = String(presentation.get("empty_title", "尚未形成国家理念"))
	_empty_detail.text = String(presentation.get("empty_detail",
		"积累理念点后抽取。"))
	if _empty_insights != null:
		_empty_insights.visible = false


# --- test-facing API --------------------------------------------------------

func hint_text() -> String:
	return _hint.text if _hint != null else ""


func offer_button_disabled() -> bool:
	return true if _offer_button == null else _offer_button.disabled


func empty_state_visible() -> bool:
	return false if _empty == null else _empty.visible


func slots_capacity() -> int:
	return int(_presentation.get("slots_capacity", 0))


func points_text() -> String:
	return String(_presentation.get("points_text", ""))


func offer_choice_summaries() -> PackedStringArray:
	var summaries := PackedStringArray()
	for index in 3:
		var card: Control = _choice(index) if _choice_0 != null else null
		if card == null or not card.visible or int(card.get("ideology_id")) < 0:
			continue
		var data: Dictionary = card.call("card_data")
		var effects := PackedStringArray(data.get("effects", PackedStringArray()))
		summaries.append("%s：%s" % [String(data.get("display_name", "")),
			"、".join(effects)])
	return summaries


func niche_count(kind: int) -> int:
	# Logical slot count, not rendered rows: empty slots collapse into one drop
	# row, so the child count would under-report the board.
	return int(_presentation.get("slots_capacity" if kind == 1 else "spirits_capacity", 0))


# --- inner drawing helpers --------------------------------------------------

## A physical deck shares the candidate row's footprint while the worker settles.
class DrawStack:
	extends Control
	const BACK_COUNT := 4
	var _backs: Array[Control] = []
	var _card_size := Vector2.ZERO
	var _tween: Tween
	var _shuffling := false

	func _init() -> void:
		name = "WaitingDeck"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for index in BACK_COUNT:
			var back := DeckBack.new()
			back.name = "DeckBack%d" % index
			back.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(back)
			IdeologyArt.attach_paper_shadow(back, 0.23 if index == BACK_COUNT - 1 else 0.12)
			_backs.append(back)
		set_card_size(Vector2(208, 276))

	func set_card_size(card_size: Vector2) -> void:
		if _card_size.is_equal_approx(card_size):
			return
		var resume := _shuffling
		stop()
		_card_size = card_size
		custom_minimum_size = card_size
		_layout()
		if resume:
			play(true)

	func play(animate: bool) -> void:
		stop()
		if not animate:
			return
		_shuffling = true
		var top := _backs.back() as Control
		var rest := top.position
		var rest_rotation := top.rotation
		_tween = create_tween().set_loops()
		_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(top, "position", rest + Vector2(_card_size.x * 0.12, -8), 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation + 0.08, 0.65)
		_tween.tween_property(top, "position", rest, 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation, 0.65)

	func stop() -> void:
		_shuffling = false
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = null
		_layout()

	func is_shuffling() -> bool:
		return _shuffling

	func _layout() -> void:
		for index in _backs.size():
			var back := _backs[index]
			back.size = _card_size * 0.84
			back.pivot_offset = back.size * 0.5
			back.position = (_card_size - back.size) * 0.5 + Vector2(index * 2 - 3, -index * 2)
			back.rotation = deg_to_rad(-5.0 + index * 2.0)
			back.queue_redraw()


## Paper, inset, stamped linework and emblem remain separate material layers.
class DeckBack:
	extends Control
	func _draw() -> void:
		if size.x < 20:
			return
		IdeologyArt.paper_style(0).draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
		var inset := maxf(8, size.x * 0.065)
		var face := Rect2(Vector2.ZERO, size).grow(-inset)
		IdeologyArt.paper_style(0, Color(0.27, 0.36, 0.29)).draw(get_canvas_item(), face)
		var line := Color(0.87, 0.72, 0.42, 0.68)
		draw_rect(face.grow(-6), line, false, 1.0)
		draw_rect(face.grow(-10), Color(line, 0.20), false, 1.0)
		var center := size * 0.5
		var radius := size.x * 0.23
		for side in [-1, 1]:
			var y: float = center.y + side * size.y * 0.29
			draw_line(Vector2(center.x - radius, y), Vector2(center.x + radius, y), line, 1, true)
			draw_circle(Vector2(center.x, y), 3, line)
		draw_circle(center + Vector2(0, 2), radius + 3, Color(0.05, 0.04, 0.02, 0.15))
		draw_circle(center, radius, Color(0.91, 0.83, 0.65))
		draw_arc(center, radius - 4, 0, TAU, 64, line.darkened(0.25), 1, true)
		var emblem := IconCatalog.texture_for_key(&"hud.country.ideology")
		if emblem != null:
			var extent := Vector2.ONE * radius * 1.45
			draw_texture_rect(emblem, Rect2(center - extent * 0.5, extent), false)


## Section chrome is drawn at the section boundary so the difference is legible
## before its rows enter the scroll viewport. Ordinary ideas get a clipped
## vermilion bookmark; spirits get a forest ribbon with a centred gold crest.
class SlotSectionChrome:
	extends Control
	var kind := 1

	func _draw() -> void:
		if size.x < 24.0 or size.y < 16.0:
			return
		if kind == 1:
			var spine := Rect2(0.0, 3.0, 7.0, size.y - 6.0)
			draw_rect(spine, Color(0.53, 0.15, 0.10, 0.84))
			draw_rect(Rect2(7.0, 5.0, size.x - 7.0, 1.0),
				Color(0.46, 0.29, 0.14, 0.34))
			draw_line(Vector2(12.0, size.y - 7.0),
				Vector2(size.x - 12.0, size.y - 7.0),
				Color(0.46, 0.29, 0.14, 0.20), 1.0)
			draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, 3.0), Vector2(7.0, 3.0), Vector2(7.0, 9.0),
			]), Color(0.72, 0.52, 0.24, 0.64))
			return
		var inset := Rect2(2.0, 2.0, size.x - 4.0, size.y - 4.0)
		draw_rect(inset, Color(0.10, 0.18, 0.12, 0.72))
		draw_rect(inset.grow(-3.0), Color(0.79, 0.62, 0.30, 0.68),
			false, 1.0)
		draw_line(Vector2(18.0, inset.position.y + 7.0),
			Vector2(inset.end.x - 18.0, inset.position.y + 7.0),
			Color(0.89, 0.72, 0.39, 0.42), 1.0)
		draw_line(Vector2(18.0, inset.end.y - 7.0),
			Vector2(inset.end.x - 18.0, inset.end.y - 7.0),
			Color(0.89, 0.72, 0.39, 0.26), 1.0)
		var cx := size.x * 0.5
		draw_line(Vector2(cx - 12.0, inset.position.y + 7.0),
			Vector2(cx + 12.0, inset.position.y + 7.0),
			Color(0.86, 0.68, 0.35, 0.72), 1.0)


class ResonanceEmblem:
	extends VBoxContainer
	signal activated(school_id: String)
	var school_id := ""
	var _icon: TextureRect
	var _count: Label
	var _pips: HBoxContainer
	var _pressing := false
	var _press_pos := Vector2.ZERO

	func configure(school: String) -> void:
		school_id = school
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 1)
		custom_minimum_size = Vector2(52, 0)
		_icon = TextureRect.new()
		_icon.texture = IdeologyArt.emblem_for(school)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.custom_minimum_size = Vector2(22, 22)
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
		_count = IdeologyArt.label(IdeologyArt.school_name(school), 10,
			IdeologyArt.school_color(school))
		add_child(_count)
		_pips = HBoxContainer.new()
		_pips.visible = false
		_pips.alignment = BoxContainer.ALIGNMENT_CENTER
		_pips.add_theme_constant_override("separation", 4)
		_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pips)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_LEFT:
				if mouse.pressed:
					_pressing = true
					_press_pos = mouse.position
				elif _pressing:
					_pressing = false
					if mouse.position.distance_to(_press_pos) <= 12.0:
						activated.emit(school_id)
						accept_event()

	func set_compact(compact: bool) -> void:
		_icon.custom_minimum_size = Vector2(18, 18) if compact else Vector2(22, 22)
		custom_minimum_size.x = 38 if compact else 52
		_count.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		_pips.visible = false

	func set_state(count: int, preview_count: int, tiers: Array[Dictionary]) -> void:
		var school_label := IdeologyArt.school_name(school_id)
		_count.text = "%s %d" % [school_label, count] if preview_count == count \
			else "%s %d→%d" % [school_label, count, preview_count]
		_count.add_theme_color_override("font_color", IdeologyArt.VERMILION
			if preview_count != count else IdeologyArt.school_color(school_id))
		for child in _pips.get_children():
			_pips.remove_child(child)
			child.queue_free()
		var tips := PackedStringArray()
		var any_active := false
		for tier in tiers:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(9, 9)
			pip.pivot_offset = Vector2(4.5, 4.5)
			# Diamonds read as inked seals; flat squares read as debug swatches.
			pip.rotation = PI * 0.25
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var active := bool(tier.get("active", false))
			var reach := preview_count >= int(tier.get("min_count", 99)) and not active
			any_active = any_active or active
			pip.color = IdeologyArt.VERMILION if active else (
				Color(0.86, 0.67, 0.30, 0.9) if reach else Color(0.45, 0.36, 0.26, 0.30))
			_pips.add_child(pip)
			tips.append("%s%s" % ["● " if active else "○ ", String(tier.get("tooltip", ""))])
		tooltip_text = "\n".join(tips)
		_icon.modulate = Color.WHITE if any_active or count > 0 else Color(1, 1, 1, 0.45)

	func celebrate() -> void:
		pivot_offset = size * 0.5
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.05, 1.05), 0.1)
		tween.tween_property(self, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## A collection entry is a physical card in the archive, not a text row. The
## authored frame carries rarity; the face reserves its space for school,
## current effect, a brass level seal and a full-width understanding track.
class CollectionEntry:
	extends Control
	var _name: Label
	var _effects: Label
	var _emblem: TextureRect
	var _footer: HBoxContainer
	var _level_meter: Control
	var _payload := {}
	var _draggable := true
	var _surface: CardSurface
	var _face: MarginContainer
	var _column: VBoxContainer
	var _band: HBoxContainer
	var _rarity := 1
	var _hover_tween: Tween
	var _status: Label
	var _detail_model: Dictionary = {}
	var _action_well: MarginContainer
	var _head: HBoxContainer
	var _compact := false
	var _pressing := false
	var _press_pos := Vector2.ZERO
	var _press_moved := false

	func setup(data: Dictionary) -> void:
		_detail_model = data.get("detail_model", {})
		_payload = data.get("payload", {}).duplicate()
		_payload["activated"] = data.get("activated", Callable())
		_payload["detail_requested"] = data.get("detail_requested", Callable())
		_payload["locate_requested"] = data.get("locate_requested", Callable())
		_draggable = bool(data.get("draggable", true))
		_compact = bool(data.get("compact", false))
		var compact := _compact
		_rarity = clampi(int(data.get("rarity", 1)), 1, 3)
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		clip_contents = false
		_surface = CardSurface.new()
		_surface.rarity = _rarity
		_surface.accent = ArtScript.school_color(String(data.get("school_id", "")))
		_surface.compact = compact
		_surface.rarity_glow = ArtScript.rarity_glow(_rarity)
		_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_surface)
		_face = MarginContainer.new()
		_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 纸面只保留统一内边距；文字、理解度和操作由同一列容器顺排。
		for side in ["left", "top", "right", "bottom"]:
			_face.add_theme_constant_override("margin_%s" % side, 18)
		add_child(_face)
		_column = VBoxContainer.new()
		_column.add_theme_constant_override("separation", 10)
		_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.add_child(_column)
		_head = HBoxContainer.new()
		_head.add_theme_constant_override("separation", 10)
		_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_head)
		_emblem = TextureRect.new()
		_emblem.texture = ArtScript.emblem_for(String(data.get("school_id", "")))
		_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_emblem.custom_minimum_size = Vector2(36, 36)
		_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(_emblem)
		var identity := VBoxContainer.new()
		identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(identity)
		_name = ArtScript.label(String(data.get("name", "")), 22,
			ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_name.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
		_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		identity.add_child(_name)
		_status = ArtScript.label("", 15, ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_LEFT)
		identity.add_child(_status)
		refresh_status(bool(data.get("pending", false)), int(data.get("location", 0)))
		var edition := ArtScript.label(String(ArtScript.RARITY_NAMES[_rarity]),
			15, ArtScript.rarity_accent(_rarity), HORIZONTAL_ALIGNMENT_RIGHT)
		edition.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_head.add_child(edition)
		_effects = ArtScript.label("", 17, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_effects.text = "\n".join(data.get("effects", PackedStringArray()))
		_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_effects.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_effects)
		_band = HBoxContainer.new()
		_band.name = "LevelSealBand"
		_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_band.add_theme_constant_override("separation", 8)
		_column.add_child(_band)
		var meter_data: Dictionary = data.get("level_progress", {})
		meter_data["accent"] = ArtScript.GOLD_LEAF.lerp(
			ArtScript.school_color(String(data.get("school_id", ""))), 0.12)
		_level_meter = LevelMeterScript.new()
		_level_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_level_meter.configure(meter_data, compact)
		_band.add_child(_level_meter)
		_action_well = MarginContainer.new()
		_action_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_action_well.add_theme_constant_override("margin_top", 4)
		_action_well.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_column.add_child(_action_well)
		_footer = HBoxContainer.new()
		_footer.alignment = BoxContainer.ALIGNMENT_END
		_footer.add_theme_constant_override("separation", 8)
		_footer.size_flags_vertical = Control.SIZE_SHRINK_END
		_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_footer.visible = false
		_action_well.add_child(_footer)
		_column.minimum_size_changed.connect(_queue_layout)

		var tip_lines := PackedStringArray([String(data.get("name", ""))])
		var detail := String(data.get("detail", "")).strip_edges()
		if not detail.is_empty() and not detail.contains("."):
			tip_lines.append(detail)
		var effect_values: PackedStringArray = data.get("effects", PackedStringArray())
		for effect in effect_values:
			if not String(effect).strip_edges().is_empty():
				tip_lines.append("· %s" % String(effect))
		tooltip_text = String(data.get("tooltip", "\n".join(tip_lines)))
		gui_input.connect(_on_input)
		mouse_entered.connect(_set_hover.bind(true))
		mouse_exited.connect(_set_hover.bind(false))
		focus_entered.connect(_set_hover.bind(true))
		focus_exited.connect(_set_hover.bind(false))
		_apply_scaled_layout()

	func footer() -> HBoxContainer:
		return _footer

	func refresh_status(pending: bool, location: int) -> void:
		_status.text = "待生效" if pending else "推行中" if location == 1 else "民族精神" if location == 2 else ""
		_status.visible = not _status.text.is_empty()
		if not _detail_model.is_empty():
			_detail_model["status"] = "待生效" if pending else "推行中" \
				if location == 1 else "民族精神" if location == 2 else "尚未推行"

	func refresh_support_details(supports: Array[Dictionary]) -> void:
		if not _detail_model.is_empty():
			_detail_model["supports"] = supports

	func refresh_progress(data: Dictionary) -> void:
		if _level_meter != null:
			_level_meter.configure(data, _compact)
		if not _detail_model.is_empty():
			var progress := data.duplicate(false)
			progress.erase("accent")
			_detail_model["progress"] = progress

	func refresh_card_data(data: Dictionary) -> void:
		tooltip_text = String(data.get("tooltip", ""))
		set_detail_model(data.get("detail_model", {}))
		var effects: PackedStringArray = data.get("effects", PackedStringArray())
		_effects.text = "\n".join(effects)
		refresh_progress(data.get("level_progress", {}))

	func level_meter() -> Control:
		return _level_meter

	func refresh_layout() -> void:
		_apply_scaled_layout()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_apply_scaled_layout()

	func _queue_layout() -> void:
		call_deferred("_apply_scaled_layout")

	func _apply_scaled_layout() -> void:
		if _face == null or _column == null or size.x < 1.0:
			return
		# 正文完整换行后决定卡高；操作始终位于理解度下方。
		var required := ceilf(_column.get_combined_minimum_size().y + 36.0)
		custom_minimum_size.y = maxf(208.0, required)

	func _make_custom_tooltip(for_text: String) -> Object:
		return ArtScript.detail_tooltip(for_text, _detail_model)

	func set_detail_model(data: Dictionary) -> void:
		_detail_model = data

	func frame_path() -> String:
		return ArtScript.PAPER_SHEET

	func play_deal_in(delay := 0.0) -> void:
		if not is_inside_tree() or UIAnimation.reduced_motion():
			return
		pivot_offset = size * 0.5
		scale = Vector2(0.94, 0.94)
		modulate.a = 0.0
		var tween := create_tween().set_parallel(true)
		tween.tween_interval(delay)
		tween.tween_property(self, "modulate:a", 1.0, 0.24) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "scale", Vector2.ONE, 0.30) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _set_hover(on: bool) -> void:
		if _hover_tween != null and _hover_tween.is_valid():
			_hover_tween.kill()
		_hover_tween = create_tween().set_parallel(true)
		_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_hover_tween.tween_property(_surface, "hover_lift", 1.0 if on else 0.0, 0.15)
		_hover_tween.tween_property(self, "self_modulate",
			Color(1.035, 1.025, 0.985) if on else Color.WHITE, 0.15)

	func _on_input(event: InputEvent) -> void:
		if ArtScript.scroll_detail(event):
			accept_event()
			return
		if event.is_action_pressed(&"ui_accept"):
			_payload.get("activated", Callable()).call()
			accept_event()
			return
		if event is InputEventMouseMotion:
			if _pressing and (event as InputEventMouseMotion).position.distance_to(_press_pos) > 10.0:
				_press_moved = true
			return
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_RIGHT:
				if mouse.pressed:
					var locate_cb: Callable = _payload.get("locate_requested", Callable())
					if locate_cb.is_valid():
						locate_cb.call()
						accept_event()
				return
			if mouse.button_index == MOUSE_BUTTON_LEFT:
				if mouse.pressed:
					_pressing = true
					_press_pos = mouse.position
					_press_moved = false
				else:
					var was_tap := _pressing and not _press_moved
					_pressing = false
					if mouse.double_click:
						_payload.get("activated", Callable()).call()
						accept_event()
					elif was_tap:
						var detail_cb: Callable = _payload.get("detail_requested", Callable())
						if detail_cb.is_valid():
							detail_cb.call()
							accept_event()

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if not _draggable or TouchUI.is_touch():
			return null
		var holder := Control.new()
		var preview := NinePatchRect.new()
		preview.texture = ArtScript.collection_frame_for(_rarity)
		preview.size = Vector2(220, 148)
		preview.position = -preview.size * 0.5
		preview.patch_margin_left = 0
		preview.patch_margin_right = 0
		preview.patch_margin_top = 0
		preview.patch_margin_bottom = 0
		preview.rotation = -0.035
		holder.add_child(preview)
		var label := ArtScript.label(_name.text, 16, ArtScript.INK)
		label.add_theme_font_override("font",
			preload("res://assets/fonts/muyao/display_handwritten.tres"))
		label.position = -preview.size * 0.5 + Vector2(18, 18)
		label.size = Vector2(preview.size.x - 24, 24)
		holder.add_child(label)
		set_drag_preview(holder)
		return _payload.duplicate()


## Independent paper, edition edging and diffuse shadow layers.
class CardSurface:
	extends Control
	var rarity := 1
	var accent := Color(0.3, 0.22, 0.14)
	var rarity_glow := Color(0.88, 0.79, 0.59, 0.20)
	var compact := false
	var hover_lift := 0.0:
		set(value):
			hover_lift = value
			queue_redraw()

	func _init() -> void:
		ArtScript.attach_paper_shadow(self, 0.16)

	func _draw() -> void:
		if size.x < 20.0 or size.y < 20.0:
			return
		var rect := Rect2(Vector2.ZERO, size)
		draw_style_box(ArtScript.paper_style(0.0, ArtScript.paper_tint(rarity)), rect)
		if rarity >= 2:
			draw_style_box(ArtScript.edition_style(rarity), rect)
		# A school-coloured paper tab and ink rule are independent layers.
		draw_style_box(ArtScript.paper_style(0.0, accent.lightened(0.12)),
			Rect2(0, 16, 6, 40))
		if hover_lift > 0.01:
			draw_rect(rect.grow(-3), Color(accent, 0.35 * hover_lift), false, 1.0)

# G5 responsibility adapters. Mutable state remains in this host.
func _build_promotion_overlay() -> void:
	_presentation_component._build_promotion_overlay(self)

func _wire_promotion_focus() -> void:
	_presentation_component._wire_promotion_focus(self)

func _close_promotion_overlay() -> void:
	_presentation_component._close_promotion_overlay(self)

func _open_detail_modal(ideology_id: int, is_offer: bool = false) -> void:
	_presentation_component._open_detail_modal(self, ideology_id, is_offer)

func _open_resonance_detail(school_id: String) -> void:
	_presentation_component._open_resonance_detail(self, school_id)

func _present_detail_dictionary(data: Dictionary) -> void:
	_presentation_component._present_detail_dictionary(self, data)

func _close_detail_modal() -> void:
	_presentation_component._close_detail_modal(self)

func is_detail_modal_open() -> bool:
	return _presentation_component.is_detail_modal_open(self)

func _focus_initial_action() -> void:
	_presentation_component._focus_initial_action(self)

func _build_dynamic_parts() -> void:
	_presentation_component._build_dynamic_parts(self)

func _build_archive_chrome() -> void:
	_presentation_component._build_archive_chrome(self)

func _build_deck_heading() -> void:
	_presentation_component._build_deck_heading(self)

func _build_slot_sections(deck_column: VBoxContainer) -> void:
	_presentation_component._build_slot_sections(self, deck_column)

func _make_slot_section_header(kind: int) -> PanelContainer:
	return _presentation_component._make_slot_section_header(self, kind)

func _spirit_alcove_rule_style() -> StyleBoxFlat:
	return _presentation_component._spirit_alcove_rule_style(self)

func _build_collection_heading() -> void:
	_presentation_component._build_collection_heading(self)

func _style_school_tabs() -> void:
	_presentation_component._style_school_tabs(self)

func _tab_style(state: String) -> StyleBox:
	return _presentation_component._tab_style(self, state)

func _apply_archive_metrics() -> void:
	_presentation_component._apply_archive_metrics(self)

func _play_workspace_intro() -> void:
	_presentation_component._play_workspace_intro(self)

func _build_stage_scenery() -> void:
	_presentation_component._build_stage_scenery(self)

func _build_stage_header() -> void:
	_presentation_component._build_stage_header(self)

func _build_stage_footer() -> void:
	_presentation_component._build_stage_footer(self)

func set_model(model: Dictionary) -> void:
	_presentation_component.set_model(self, model)

func refresh_model(model: Dictionary) -> void:
	_presentation_component.refresh_model(self, model)

func set_compact(compact: bool) -> void:
	_presentation_component.set_compact(self, compact)

func _safe_insets() -> Dictionary:
	return _presentation_component._safe_insets(self)

func _apply_offer_layer_insets() -> void:
	_presentation_component._apply_offer_layer_insets(self)

func _stage_card_size() -> Vector2:
	return _presentation_component._stage_card_size(self)

func _apply_stage_metrics() -> void:
	_presentation_component._apply_stage_metrics(self)

func _on_workspace_resized() -> void:
	_presentation_component._on_workspace_resized(self)

func set_player_controller(controller) -> void:
	_presentation_component.set_player_controller(self, controller)

func _apply_model(model: Dictionary) -> void:
	_presentation_component._apply_model(self, model)

func _index_catalog() -> void:
	_presentation_component._index_catalog(self)

func _index_states() -> Dictionary:
	return _presentation_component._index_states(self)

func _render_top() -> void:
	_presentation_component._render_top(self)

func _draw_waiting() -> bool:
	return _presentation_component._draw_waiting(self)

func _refresh_effect_report() -> PackedInt32Array:
	return _presentation_component._refresh_effect_report(self)

func _replace_effect_summary(summary: Dictionary) -> PackedInt32Array:
	return _presentation_component._replace_effect_summary(self, summary)

func _refresh_live_explain(known: PackedInt32Array) -> void:
	_presentation_component._refresh_live_explain(self, known)

func _rebuild_board() -> void:
	_presentation_component._rebuild_board(self)

func _board_signature(known: PackedInt32Array) -> Array:
	return _presentation_component._board_signature(self, known)

func _slot_row_data(ideology_id: int, kind: int) -> Dictionary:
	return _presentation_component._slot_row_data(self, ideology_id, kind)

func _next_milestone(kind: int) -> String:
	return _presentation_component._next_milestone(self, kind)

func _locked_captions(kind: int) -> PackedStringArray:
	return _presentation_component._locked_captions(self, kind)

func _rebuild_collection(known: PackedInt32Array) -> void:
	_presentation_component._rebuild_collection(self, known)

func _on_collection_resized() -> void:
	_presentation_component._on_collection_resized(self)

func _apply_collection_columns() -> void:
	_presentation_component._apply_collection_columns(self)

func _collection_max_card_width() -> float:
	return _presentation_component._collection_max_card_width(self)

func _update_collection_metrics(_visible_count: int) -> void:
	_presentation_component._update_collection_metrics(self, _visible_count)

func _sort_less(a: int, b: int) -> bool:
	return _presentation_component._sort_less(self, a, b)

func _make_collection_entry(ideology_id: int) -> Control:
	return _presentation_component._make_collection_entry(self, ideology_id)

func _action_button(text: String, disabled: bool, callback: Callable,
		tooltip: String, _compact_value := false) -> Button:
	return _presentation_component._action_button(self, text, disabled, callback, tooltip, _compact_value)

func _secondary_action_button(text: String, callback: Callable,
		tooltip: String, compact_value := false) -> Button:
	return _presentation_component._secondary_action_button(self, text, callback, tooltip, compact_value)

func _on_card_locate_requested(ideology_id: int) -> void:
	_presentation_component._on_card_locate_requested(self, ideology_id)

func _card_data(ideology_id: int, in_collection: bool) -> Dictionary:
	return _presentation_component._card_data(self, ideology_id, in_collection)

func _detail_data(ideology_id: int, offer := false) -> Dictionary:
	return _presentation_component._detail_data(self, ideology_id, offer)

func _id_set(ids: PackedInt32Array) -> Dictionary:
	return _presentation_component._id_set(self, ids)

func _progress_data(ideology_id: int) -> Dictionary:
	return _presentation_component._progress_data(self, ideology_id)

func _support_details(live: Dictionary, location: int) -> Array[Dictionary]:
	return _presentation_component._support_details(self, live, location)

func _school_counts(extra_id: int) -> Dictionary:
	return _presentation_component._school_counts(self, extra_id)

func _update_resonance(_niche: Control, preview_id: int) -> void:
	_presentation_component._update_resonance(self, _niche, preview_id)

func _on_niche_drop(ideology_id: int, from_location: int, kind: int) -> void:
	_presentation_component._on_niche_drop(self, ideology_id, from_location, kind)

func _on_niche_hover(ideology_id: int, kind: int, entered: bool, niche: Control) -> void:
	_presentation_component._on_niche_hover(self, ideology_id, kind, entered, niche)

func _can_drop_collection(_at_position: Vector2, data: Variant) -> bool:
	return _presentation_component._can_drop_collection(self, _at_position, data)

func _drop_collection(_at_position: Vector2, data: Variant) -> void:
	_presentation_component._drop_collection(self, _at_position, data)
