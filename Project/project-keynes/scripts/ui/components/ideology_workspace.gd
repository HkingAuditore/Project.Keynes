extends Control
class_name IdeologyWorkspace

const WorkspaceControls = preload("res://scripts/ui/components/ideology_workspace_controls.gd")

const OfferCards = preload("res://scripts/ui/components/ideology_offer_cards.gd")

const OfferCommands = preload("res://scripts/ui/components/ideology_offer_commands.gd")

const IdeologyWaitingDeck = preload("res://scripts/ui/components/ideology_waiting_deck.gd")
const DrawStack = IdeologyWaitingDeck.DrawStack
const DeckBack = IdeologyWaitingDeck.DeckBack
const IdeologySlotChrome = preload("res://scripts/ui/components/ideology_slot_chrome.gd")
const SlotSectionChrome = IdeologySlotChrome.SlotSectionChrome
const ResonanceEmblem = IdeologySlotChrome.ResonanceEmblem
const IdeologyCollectionCard = preload("res://scripts/ui/components/ideology_collection_card.gd")
const CollectionEntry = IdeologyCollectionCard.CollectionEntry
const CardSurface = IdeologyCollectionCard.CardSurface

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const IdeologySupport = preload("res://scripts/ui/components/ideology_workspace_support.gd")
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
var _pending_draw_sequence := -1
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
	WorkspaceControls._bind_nodes(self)


func _build_detail_overlay() -> void:
	WorkspaceControls._build_detail_overlay(self)


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
	OfferCommands._open_offer(self)


func _reroll_offer() -> void:
	OfferCommands._reroll_offer(self)


func _dismiss_offer() -> void:
	OfferCommands._dismiss_offer(self)


func _command(kind: String, ideology_id: int) -> void:
	OfferCommands._command(self, kind, ideology_id)


func _request_promotion(ideology_id: int) -> void:
	OfferCommands._request_promotion(self, ideology_id)


func _confirm_promotion() -> void:
	OfferCommands._confirm_promotion(self)


func _on_player_command_completed(id: StringName, result: Dictionary) -> void:
	OfferCommands._on_player_command_completed(self, id, result)


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	OfferCommands._on_player_command_settled(self, id, result)


func _on_ideology_offer_ready(snapshot: Dictionary) -> void:
	OfferCommands._on_ideology_offer_ready(self, snapshot)


func _show_result(result: Dictionary) -> void:
	OfferCommands._show_result(self, result)


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
	OfferCards._rebuild_offer(self)


func _render_draw_waiting() -> void:
	OfferCards._render_draw_waiting(self)


func _apply_offer_card_tilt(card: Control, _index: int, _rarity: int) -> void:
	OfferCards._apply_offer_card_tilt(self, card, _index, _rarity)


func _set_draw_stack(show: bool) -> void:
	OfferCards._set_draw_stack(self, show)


func _set_stage_visible(show: bool) -> void:
	OfferCards._set_stage_visible(self, show)


func _play_reveal(count: int) -> void:
	OfferCards._play_reveal(self, count)


func _finish_offer_animation() -> void:
	OfferCards._finish_offer_animation(self)


func _on_choice_input(event: InputEvent, index: int) -> void:
	OfferCards._on_choice_input(self, event, index)


func _on_choice_activated(_ideology_id: int, index: int) -> void:
	OfferCards._on_choice_activated(self, _ideology_id, index)


func _on_choice_detail_requested(ideology_id: int) -> void:
	OfferCards._on_choice_detail_requested(self, ideology_id)


func _choose_offer(choice_index: int) -> void:
	OfferCards._choose_offer(self, choice_index)


func _play_choose(choice_index: int) -> void:
	OfferCards._play_choose(self, choice_index)


func _finish_choose_animation() -> void:
	OfferCards._finish_choose_animation(self)


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
	var line := "%s支持条件 · 评分 %s / 门槛 %s" % [action,
		_q16_signed(int(support.get("support_q16", 0))),
		_q16_signed(int(support.get("threshold_q16", 0)))]
	if int(support.get("blocking_class", -1)) >= 0:
		line += "（关键阶层未达到最低支持要求）"
	return line


func _support_tooltip(live: Dictionary, direction: int) -> String:
	return IdeologySupport.tooltip(self, live, direction)


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
	return IdeologySupport._support_details(self, live, location)

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
