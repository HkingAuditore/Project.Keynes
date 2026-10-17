extends Control
class_name IdeologyWorkspace

# Papercut deck-building view over the native ideology authority. Facade-only:
# every mutation is a PlayerController command, and rows are rebuilt only when
# the compact native snapshot signature changes. Animation state never feeds
# back into gameplay state.

const Q16_ONE := 65536.0
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CardScript = preload("res://scripts/ui/components/ideology_card.gd")
const NicheScript = preload("res://scripts/ui/components/ideology_slot_niche.gd")
const PointScrollScript = preload("res://scripts/ui/components/ideology_point_scroll.gd")
const DROP_STAGGER := 0.12
const HINT_HOLD_MSEC := 4500
const SORT_LABELS := ["收录顺序", "稀有度", "流派", "境界"]
## Scroll-unroll mask: paper covers the stage and recedes from the centre out,
## leaving a darker rod edge at the reveal front.
const UNROLL_SHADER := """
shader_type canvas_item;
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
uniform vec4 paper : source_color = vec4(0.93, 0.87, 0.74, 1.0);
uniform vec4 rod : source_color = vec4(0.36, 0.22, 0.11, 1.0);
void fragment() {
	float d = abs(UV.x - 0.5) * 2.0;
	if (d < reveal) { discard; }
	float edge = smoothstep(reveal, reveal + 0.035, d);
	float fibre = 0.04 * sin(UV.y * 180.0 + UV.x * 23.0);
	COLOR = mix(rod, paper + vec4(fibre, fibre, fibre, 0.0), edge);
}
"""

## Session-wide accessibility preference shared by every workspace instance.
static var reduce_motion := false

var _facade = null
var _player_controller = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _presentation: Dictionary = {}
var _live_explain: Dictionary = {}
var _live_by_id := {}
var _metadata := {}
var _dense_by_stable := {}
var _states := {}
var _signature := ""
var _explain_signature := ""
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
var _progress_by_id := {}

var _root: VBoxContainer
var _point_scroll: Control
var _hint: Label
var _offer_button: Button
var _motion_toggle: CheckBox
var _offer: PanelContainer
var _offer_title: Label
var _choice_0: Control
var _choice_1: Control
var _choice_2: Control
var _reroll_button: Button
var _dismiss_button: Button
var _unroll_mask: ColorRect
var _tear: TornPaper
var _deck: PanelContainer
var _link_layer: LinkLayer
var _deck_caption: Label
var _ideology_label: Label
var _spirit_label: Label
var _ideology_slots: HFlowContainer
var _spirit_slots: HFlowContainer
var _resonance_bar: HBoxContainer
var _resonance_views := {}
var _tabs: TabBar
var _sort: OptionButton
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
var _ledger_popup: PopupPanel


func _ready() -> void:
	_bind_nodes()
	if _empty_icon != null:
		_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)


func _bind_nodes() -> void:
	if _offer_button != null:
		return
	_root = get_node_or_null("Root") as VBoxContainer
	_point_scroll = %PointScroll
	_hint = %Hint
	_offer_button = %OpenOffer
	_motion_toggle = %ReduceMotion
	_offer = %Offer
	_offer_title = %OfferTitle
	_choice_0 = %Choice0
	_choice_1 = %Choice1
	_choice_2 = %Choice2
	_reroll_button = %Reroll
	_dismiss_button = %Dismiss
	_deck = %DeckTable
	_deck_caption = %DeckCaption
	_ideology_label = %IdeologyLabel
	_spirit_label = %SpiritLabel
	_ideology_slots = %IdeologySlots
	_spirit_slots = %SpiritSlots
	_resonance_bar = %ResonanceBar
	_tabs = %SchoolTabs
	_sort = %SortMode
	_collection_drop = %CollectionDrop
	_collection = %Collection
	_scroll = get_node_or_null("Root/Scroll") as ScrollContainer
	_empty = %EmptyState
	_empty_icon = %EmptyIcon
	_empty_title = %EmptyTitle
	_empty_detail = %EmptyDetail
	_empty_insights = %EmptyInsights
	_fx = %Fx
	_promotion_dialog = %PromotionDialog
	_ledger_popup = %LedgerPopup
	_build_dynamic_parts()


func _build_dynamic_parts() -> void:
	# Unroll mask and torn-paper cover sit on top of the offer stage; both are
	# drawn in place (shader uniform / draw offset) so the PanelContainer can
	# keep sizing them to the full stage.
	_unroll_mask = ColorRect.new()
	_unroll_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = UNROLL_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("reveal", 1.0)
	_unroll_mask.material = material
	_offer.add_child(_unroll_mask)
	_tear = TornPaper.new()
	_offer.add_child(_tear)
	_link_layer = LinkLayer.new()
	_deck.add_child(_link_layer)
	_deck.resized.connect(_queue_links)
	for index in 3:
		var card := _choice(index)
		card.set("draggable", false)
		card.connect("activated", _on_choice_activated.bind(index))
		card.gui_input.connect(_on_choice_input.bind(index))
	_point_scroll.connect("ledger_requested", _open_ledger)
	_motion_toggle.button_pressed = reduce_motion
	_motion_toggle.toggled.connect(_on_motion_toggled)
	_tabs.add_tab("全部")
	for school_id in ArtScript.SCHOOL_ORDER:
		_tabs.add_tab(ArtScript.school_name(String(school_id)))
	_tabs.tab_changed.connect(_on_tab_changed)
	for label in SORT_LABELS:
		_sort.add_item(String(label))
	_sort.item_selected.connect(_on_sort_selected)
	_collection_drop.set_drag_forwarding(Callable(), _can_drop_collection,
		_drop_collection)
	for school_id in ArtScript.SCHOOL_ORDER:
		var view := ResonanceEmblem.new()
		view.configure(String(school_id))
		_resonance_bar.add_child(view)
		_resonance_views[String(school_id)] = view


func set_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func refresh_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func set_compact(compact: bool) -> void:
	_bind_nodes()
	if _compact == compact and not _signature.is_empty():
		return
	_compact = compact
	_point_scroll.custom_minimum_size = Vector2(300, 58) if compact else Vector2(380, 64)
	_empty.custom_minimum_size = Vector2(360, 150) if compact else Vector2(520, 170)
	# 720p keeps the three offer cards and their actions inside one viewport.
	var offer_cards := _choice_0.get_parent() as HBoxContainer
	if offer_cards != null:
		offer_cards.add_theme_constant_override("separation", 16 if compact else 26)
	var offer_column := offer_cards.get_parent() as VBoxContainer if offer_cards != null else null
	if offer_column != null:
		offer_column.add_theme_constant_override("separation", 6 if compact else 10)
	_offer_title.add_theme_font_size_override("font_size", 15 if compact else 18)
	for index in 3:
		_choice(index).call("set_compact", compact)
	for view in _resonance_views.values():
		(view as ResonanceEmblem).set_compact(compact)
	_deck_caption.visible = false
	_signature = ""
	if not _snapshot.is_empty() and not _presentation.is_empty():
		_rebuild_board()


func set_player_controller(controller) -> void:
	var bindings := {
		"command_settled": "_on_player_command_settled",
		"ideology_offer_ready": "_on_ideology_offer_ready",
		"ideology_draw_state_changed": "_on_ideology_draw_state_changed",
	}
	if _player_controller != null:
		for signal_name in bindings:
			var old_callback := Callable(self, String(bindings[signal_name]))
			if _player_controller.has_signal(signal_name) \
					and _player_controller.is_connected(signal_name, old_callback):
				_player_controller.disconnect(signal_name, old_callback)
	_player_controller = controller
	if _player_controller == null:
		return
	for signal_name in bindings:
		var callback := Callable(self, String(bindings[signal_name]))
		if _player_controller.has_signal(signal_name) \
				and not _player_controller.is_connected(signal_name, callback):
			_player_controller.connect(signal_name, callback)
	if _player_controller.has_method("ideology_draw_phase"):
		_draw_phase = String(_player_controller.ideology_draw_phase())


# --- model ----------------------------------------------------------------

func _apply_model(model: Dictionary) -> void:
	var ideology: Dictionary = model.get("ideology", {})
	_facade = ideology.get("facade")
	_country_handle = int(model.get("country_handle", 0))
	_current_day = int(model.get("current_day", 0))
	if ideology.is_empty() or not bool(ideology.get("available", false)):
		var raw_reason := String(ideology.get("reason", model.get("reason", "")))
		var loading := ideology.is_empty() and not bool(model.get("available", false)) \
			and (raw_reason.is_empty() or raw_reason == "正在载入已提交数据")
		_show_shell(CountryViewModel.ideology_player_reason(raw_reason), loading)
		return
	_catalog = ideology.get("catalog", {})
	_snapshot = ideology.get("snapshot", {})
	_presentation = ideology.get("presentation", {})
	if _presentation.is_empty():
		_presentation = CountryViewModel.present_ideology(_snapshot, _catalog)
	if _player_controller != null and _player_controller.has_method("ideology_draw_phase"):
		_draw_phase = String(_player_controller.ideology_draw_phase())
	_index_catalog()
	_index_states()
	_render_top()
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	var explain_signature := "%d|%d|%s|%s|%s|%s" % [
		_country_handle, int(_snapshot.get("support_revision", 0)), known,
		_snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("locations", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray())]
	if explain_signature != _explain_signature:
		_explain_signature = explain_signature
		_refresh_live_explain(known)
	var signature := "%s|%s|%s|%s|%s|%d|%d|%d|%d|%s|%d|%d" % [known,
		_snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("locations", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray()),
		_snapshot.get("active_synergy_ids", PackedInt32Array()),
		int(_presentation.get("slots_capacity", 0)),
		int(_presentation.get("spirits_capacity", 0)),
		int(_live_explain.get("support_revision", 0)),
		_metadata.size(), _tab_school, _sort_mode, int(_compact)]
	if signature != _signature:
		_signature = signature
		_rebuild_board()
	else:
		_update_progress()
	_rebuild_offer()
	_show_empty_state(bool(_presentation.get("empty", known.is_empty())), _presentation)


func _index_catalog() -> void:
	var rows: Array = _catalog.get("ideologies", [])
	if rows.size() == _metadata.size() and not _metadata.is_empty():
		return
	_metadata.clear()
	_dense_by_stable.clear()
	for row_value in rows:
		var row := row_value as Dictionary
		var dense_id := int(row.get("dense_id", -1))
		_metadata[dense_id] = row
		_dense_by_stable[String(row.get("id", ""))] = dense_id


func _index_states() -> void:
	_states.clear()
	var ids: PackedInt32Array = _snapshot.get("idea_ids", PackedInt32Array())
	var understanding: PackedInt64Array = _snapshot.get("understanding_q16", PackedInt64Array())
	var levels: PackedInt32Array = _snapshot.get("levels", PackedInt32Array())
	var locations: PackedInt32Array = _snapshot.get("locations", PackedInt32Array())
	var pending: PackedByteArray = _snapshot.get("transition_pending", PackedByteArray())
	for index in ids.size():
		_states[int(ids[index])] = {
			"understanding": int(understanding[index]) if index < understanding.size() else 0,
			"level": int(levels[index]) if index < levels.size() else 0,
			"location": int(locations[index]) if index < locations.size() else 0,
			"pending": index < pending.size() and pending[index] != 0,
		}


func _render_top() -> void:
	var points := int(_presentation.get("points", 0))
	var cost := int(_presentation.get("offer_cost_q16", 65536))
	var gain := int(_presentation.get("last_gain_q16", 0))
	var ready := bool(_presentation.get("baseline_ready", false))
	var points_signature := "%d|%d|%d|%s" % [points, cost, gain, ready]
	if points_signature != _points_signature:
		_points_signature = points_signature
		_point_scroll.call("set_points", points, cost, gain, ready, reduce_motion)
	_point_scroll.tooltip_text = "理念点 %s / 抽取 %s\n累计 %s" % [
		_q16(points), _q16(cost), _q16(int(_presentation.get("lifetime_points_q16", 0)))]
	var offer_active := bool(_presentation.get("offer_active", false))
	var waiting := _draw_waiting()
	var generation := int(_snapshot.get("offer_generation", 0))
	var collapsed := offer_active and generation == _dismissed_generation
	_offer_button.disabled = waiting or not (bool(_presentation.get("can_open_offer", false))
		or collapsed)
	if waiting:
		_offer_button.text = "抽取中…"
	elif collapsed:
		_offer_button.text = "查看候选"
	elif offer_active:
		_offer_button.text = "候选待选"
	else:
		_offer_button.text = "抽取 · %s" % String(
			_presentation.get("offer_cost_text", ""))
	_offer_button.tooltip_text = "每次抽取消耗 %s 理念点，下次费用 +20%%" \
		% String(_presentation.get("offer_cost_text", ""))
	if Time.get_ticks_msec() >= _hint_hold_until:
		_hint.text = "" if waiting \
			else String(_presentation.get("offer_hint", ""))
		_hint.visible = not _hint.text.is_empty()
	var used := int(_presentation.get("slots_used", 0))
	var capacity := int(_presentation.get("slots_capacity", 0))
	_ideology_label.text = "意识形态  %d / %d" % [used, capacity]
	_spirit_label.text = "民族精神  %d / %d" % [int(_presentation.get("spirits_used", 0)),
		int(_presentation.get("spirits_capacity", 0))]


func _draw_waiting() -> bool:
	return _draw_phase == "offer" or _draw_phase == "reroll"


func _refresh_live_explain(known: PackedInt32Array) -> void:
	_live_explain = _facade.explain_ideologies(_country_handle, known) \
		if _facade != null and _facade.has_method("explain_ideologies") else {}
	_live_by_id.clear()
	if not bool(_live_explain.get("ok", false)):
		return
	var ids: PackedInt32Array = _live_explain.get("ideology_ids", PackedInt32Array())
	var support: PackedInt32Array = _live_explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = _live_explain.get("support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = _live_explain.get("support_blocking_classes", PackedInt32Array())
	var available: PackedByteArray = _live_explain.get("support_available", PackedByteArray())
	var allowed: PackedByteArray = _live_explain.get("support_allowed", PackedByteArray())
	var equip_allowed: PackedByteArray = _live_explain.get("equip_allowed", PackedByteArray())
	var unequip_allowed: PackedByteArray = _live_explain.get("unequip_allowed", PackedByteArray())
	var promote_allowed: PackedByteArray = _live_explain.get("promote_allowed", PackedByteArray())
	var stance_offsets: PackedInt32Array = _live_explain.get("stance_offsets", PackedInt32Array())
	var stance_classes: PackedInt32Array = _live_explain.get("stance_class_indices", PackedInt32Array())
	var influence: PackedInt64Array = _live_explain.get("class_influence", PackedInt64Array())
	var adopt_contributions: PackedInt64Array = _live_explain.get("adopt_contributions", PackedInt64Array())
	var repeal_contributions: PackedInt64Array = _live_explain.get("repeal_contributions", PackedInt64Array())
	var promote_contributions: PackedInt64Array = _live_explain.get("promote_contributions", PackedInt64Array())
	for index in ids.size():
		var support_rows: Array[Dictionary] = []
		for direction in 3:
			var row := index * 3 + direction
			support_rows.append({
				"support_q16": int(support[row]) if row < support.size() else 0,
				"threshold_q16": int(thresholds[row]) if row < thresholds.size() else 0,
				"blocking_class": int(blockers[row]) if row < blockers.size() else -1,
				"available": row < available.size() and available[row] != 0,
				"allowed": row < allowed.size() and allowed[row] != 0,
			})
		var class_rows: Array[Dictionary] = []
		var stance_begin := int(stance_offsets[index]) if index < stance_offsets.size() else 0
		var stance_end := int(stance_offsets[index + 1]) \
			if index + 1 < stance_offsets.size() else stance_begin
		for row in range(stance_begin, stance_end):
			class_rows.append({
				"class_index": int(stance_classes[row]),
				"influence": int(influence[row]),
				"contributions": [int(adopt_contributions[row]),
					int(repeal_contributions[row]), int(promote_contributions[row])],
			})
		_live_by_id[int(ids[index])] = {
			"support": support_rows,
			"classes": class_rows,
			"equip_allowed": index < equip_allowed.size() and equip_allowed[index] != 0,
			"unequip_allowed": index < unequip_allowed.size() and unequip_allowed[index] != 0,
			"promote_allowed": index < promote_allowed.size() and promote_allowed[index] != 0,
		}


# --- deck table and collection --------------------------------------------

func _rebuild_board() -> void:
	var saved_scroll := _scroll.scroll_vertical if _scroll != null else 0
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	var equipped: Array[int] = []
	var spirits: Array[int] = []
	for value in known:
		var location := int((_states.get(int(value), {}) as Dictionary).get("location", 0))
		if location == 1:
			equipped.append(int(value))
		elif location == 2:
			spirits.append(int(value))
	_fill_niches(_ideology_slots, 1, equipped,
		int(_presentation.get("slots_capacity", 0)),
		int(_presentation.get("slots_max", 0)))
	_fill_niches(_spirit_slots, 2, spirits,
		int(_presentation.get("spirits_capacity", 0)),
		int(_presentation.get("spirits_max", 0)))
	_update_resonance(null, -1)
	_rebuild_collection(known)
	_queue_links()
	if _scroll != null:
		_scroll.set_deferred("scroll_vertical", saved_scroll)


func _fill_niches(host: HFlowContainer, kind: int, hosted: Array[int], capacity: int,
		capacity_max: int) -> void:
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	var captions := _locked_captions(kind)
	var total := maxi(maxi(capacity, capacity_max), hosted.size())
	for index in total:
		var niche := NicheScript.new()
		var locked := index >= maxi(capacity, hosted.size())
		var caption := ""
		if locked:
			var locked_index := index - maxi(capacity, hosted.size())
			caption = captions[locked_index] \
				if locked_index < captions.size() else "未开放"
		else:
			caption = ""
		niche.configure(kind, locked, caption, _compact)
		niche.card_dropped.connect(_on_niche_drop)
		niche.drag_hovered.connect(_on_niche_hover.bind(niche))
		host.add_child(niche)
		if index < hosted.size():
			var card := _make_card(hosted[index], false)
			card.set("draggable", kind == 1)
			niche.host_card(card)


func _locked_captions(kind: int) -> PackedStringArray:
	var captions := PackedStringArray()
	for unlock_value in _presentation.get("capacity_unlocks", []) as Array:
		var unlock := unlock_value as Dictionary
		if bool(unlock.get("owned", false)):
			continue
		var delta := int(unlock.get("ideology_delta" if kind == 1 else "spirit_delta", 0))
		for _i in delta:
			captions.append(String(unlock.get("technology_name", "")))
	return captions


func _rebuild_collection(known: PackedInt32Array) -> void:
	for child in _collection.get_children():
		_collection.remove_child(child)
		child.queue_free()
	_progress_by_id.clear()
	var ids: Array[int] = []
	for value in known:
		var meta: Dictionary = _metadata.get(int(value), {})
		if _tab_school.is_empty() or String(meta.get("school_id", "")) == _tab_school:
			ids.append(int(value))
	if _sort_mode != 0:
		ids.sort_custom(_sort_less)
	for ideology_id in ids:
		_collection.add_child(_make_collection_entry(ideology_id))
	_update_progress()


func _sort_less(a: int, b: int) -> bool:
	var meta_a: Dictionary = _metadata.get(a, {})
	var meta_b: Dictionary = _metadata.get(b, {})
	match _sort_mode:
		1:
			if int(meta_a.get("rarity", 1)) != int(meta_b.get("rarity", 1)):
				return int(meta_a.get("rarity", 1)) > int(meta_b.get("rarity", 1))
		2:
			var school_a := ArtScript.SCHOOL_ORDER.find(String(meta_a.get("school_id", "")))
			var school_b := ArtScript.SCHOOL_ORDER.find(String(meta_b.get("school_id", "")))
			if school_a != school_b:
				return school_a < school_b
		3:
			var level_a := int((_states.get(a, {}) as Dictionary).get("level", 0))
			var level_b := int((_states.get(b, {}) as Dictionary).get("level", 0))
			if level_a != level_b:
				return level_a > level_b
	return a < b


func _make_collection_entry(ideology_id: int) -> Control:
	var state: Dictionary = _states.get(ideology_id, {})
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var entry := VBoxContainer.new()
	entry.add_theme_constant_override("separation", 3)
	var card := _make_card(ideology_id, true)
	card.set("draggable", location != 2)
	entry.add_child(card)
	var progress := ProgressBar.new()
	progress.show_percentage = false
	progress.custom_minimum_size = Vector2(0, 5)
	progress.max_value = 1.0
	progress.step = 0.001
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(progress)
	_progress_by_id[ideology_id] = progress
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 4)
	entry.add_child(actions)
	match location:
		0:
			actions.add_child(_action_button("推行", pending
				or not bool(live.get("equip_allowed", false)),
				_command.bind("equip", ideology_id), _support_summary(live, 0)))
		1:
			actions.add_child(_action_button("撤回", pending
				or not bool(live.get("unequip_allowed", false)),
				_command.bind("unequip", ideology_id), _support_summary(live, 1)))
			actions.add_child(_action_button("晋升", pending
				or int(state.get("level", 0)) < int(meta.get("min_spirit_level", 99))
				or not bool(live.get("promote_allowed", false)),
				_request_promotion.bind(ideology_id), _support_summary(live, 2)))
		_:
			actions.add_child(ArtScript.label("民族精神", 11, ArtScript.VERMILION))
	return entry


func _action_button(text: String, disabled: bool, callback: Callable,
		tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = disabled
	button.custom_minimum_size = Vector2(56, 24)
	button.add_theme_font_size_override("font_size", 11)
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button


func _make_card(ideology_id: int, in_collection: bool) -> Control:
	var card := CardScript.new()
	card.set_compact(_compact)
	card.set_card(_card_data(ideology_id, in_collection))
	card.activated.connect(_on_card_activated)
	return card


func _card_data(ideology_id: int, in_collection: bool) -> Dictionary:
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var state: Dictionary = _states.get(ideology_id, {})
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var level := maxi(0, int(state.get("level", 0)))
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var view := CountryViewModel.present_ideology_card(meta, level)
	var stamp := ""
	if pending:
		stamp = "待生效"
	elif in_collection and location == 1:
		stamp = "推行中"
	elif in_collection and location == 2:
		stamp = "精神"
	var thresholds: PackedInt64Array = meta.get("level_thresholds_q16", PackedInt64Array())
	var amount := int(state.get("understanding", 0))
	var tooltip := PackedStringArray([String(view.get("tooltip", ""))])
	if level + 1 < thresholds.size():
		tooltip.append("理解度 %s / %s" % [_q16(amount), _q16(int(thresholds[level + 1]))])
	elif not thresholds.is_empty():
		tooltip.append("已至最高境界")
	tooltip.append(_support_tooltip(live, 0 if location == 0 else 1))
	return {
		"ideology_id": ideology_id,
		"display_name": _display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"rarity_label": String(meta.get("rarity_label", "")),
		"effects": view.get("effect_lines", PackedStringArray()),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"location": location,
		"pending": pending,
		"stamp_text": stamp,
		"tooltip": "\n".join(tooltip).strip_edges(),
		"dimmed": in_collection and location != 0,
	}


func _update_progress() -> void:
	for ideology_id in _progress_by_id:
		var bar := _progress_by_id[ideology_id] as ProgressBar
		if bar == null or not is_instance_valid(bar):
			continue
		var state: Dictionary = _states.get(int(ideology_id), {})
		var meta: Dictionary = _metadata.get(int(ideology_id), {})
		var thresholds: PackedInt64Array = meta.get("level_thresholds_q16", PackedInt64Array())
		var level := maxi(0, int(state.get("level", 0)))
		var amount := int(state.get("understanding", 0))
		if level + 1 >= thresholds.size():
			bar.value = 1.0
			continue
		var low := int(thresholds[level])
		var high := int(thresholds[level + 1])
		bar.value = clampf(float(amount - low) / float(maxi(1, high - low)), 0.0, 1.0)


# --- resonance and synergy threads ----------------------------------------

func _school_counts(extra_id: int) -> Dictionary:
	var counts := {}
	for ideology_id in _states:
		var state: Dictionary = _states[ideology_id]
		if int(state.get("location", 0)) <= 0 and int(ideology_id) != extra_id:
			continue
		var school := String((_metadata.get(int(ideology_id), {}) as Dictionary).get("school_id", ""))
		counts[school] = int(counts.get(school, 0)) + 1
	return counts


func _update_resonance(_niche: Control, preview_id: int) -> void:
	var active_ids: PackedInt32Array = _snapshot.get("active_synergy_ids", PackedInt32Array())
	var active := {}
	for value in active_ids:
		active[int(value)] = true
	var counts := _school_counts(-1)
	var preview_counts := _school_counts(preview_id) if preview_id >= 0 else counts
	var newly_active: Array[String] = []
	for school_id in _resonance_views:
		var tiers: Array[Dictionary] = []
		for row_value in _catalog.get("synergies", []) as Array:
			var row := row_value as Dictionary
			if String(row.get("school_id", "")) != school_id:
				continue
			var dense_id := int(row.get("dense_id", -1))
			var on := active.has(dense_id)
			tiers.append({"min_count": int(row.get("min_count", 0)), "active": on,
				"tooltip": String(row.get("tooltip", ""))})
			if on and not _active_resonances.has(dense_id) and not _active_resonances.is_empty():
				newly_active.append(String(school_id))
		tiers.sort_custom(_tier_less)
		(_resonance_views[school_id] as ResonanceEmblem).set_state(
			int(counts.get(school_id, 0)), int(preview_counts.get(school_id, 0)), tiers)
	var had_any := not _active_resonances.is_empty()
	_active_resonances = active.duplicate()
	_active_resonances[-999] = true  # sentinel: first sync never celebrates
	if had_any and not reduce_motion:
		for school_id in newly_active:
			var view := _resonance_views[school_id] as ResonanceEmblem
			view.celebrate()
			_spawn_burst(view.get_global_rect().get_center(), false)


static func _tier_less(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("min_count", 0)) < int(b.get("min_count", 0))


func _on_motion_toggled(on: bool) -> void:
	reduce_motion = on


func _queue_links() -> void:
	if is_inside_tree():
		call_deferred("_update_links")


func _update_links() -> void:
	if _link_layer == null or not is_instance_valid(_link_layer):
		return
	var niches := _niches_by_id()
	var active_ids: PackedInt32Array = _snapshot.get("active_synergy_ids", PackedInt32Array())
	var segments: Array = []
	for row_value in _catalog.get("synergies", []) as Array:
		var row := row_value as Dictionary
		if not String(row.get("school_id", "")).is_empty():
			continue
		var dense_id := int(row.get("dense_id", -1))
		var members: Array[Control] = []
		for stable in row.get("required_ids", PackedStringArray()) as PackedStringArray:
			var niche: Control = niches.get(int(_dense_by_stable.get(String(stable), -1)))
			if niche != null:
				members.append(niche)
		if active_ids.has(dense_id):
			for index in range(1, members.size()):
				segments.append([_layer_point(members[index - 1]), _layer_point(members[index]),
					false, String(row.get("display_name", ""))])
		elif _hover_niche != null and _hover_id >= 0:
			# Drag preview: dashed thread when the hovered card would complete it.
			var required: PackedStringArray = row.get("required_ids", PackedStringArray())
			var hover_stable := String((_metadata.get(_hover_id, {}) as Dictionary).get("id", ""))
			if required.has(hover_stable) and members.size() == required.size() - 1:
				for member in members:
					segments.append([_layer_point(_hover_niche), _layer_point(member), true,
						String(row.get("display_name", ""))])
	_link_layer.segments = segments
	_link_layer.queue_redraw()


func _niches_by_id() -> Dictionary:
	var out := {}
	for host in [_ideology_slots, _spirit_slots]:
		for child in (host as Node).get_children():
			var occupied := int(child.get("occupied_id"))
			if occupied >= 0:
				out[occupied] = child
	return out


func _layer_point(niche: Control) -> Vector2:
	return niche.get_global_rect().get_center() - _link_layer.get_global_rect().position


# --- drag and drop --------------------------------------------------------

func _on_niche_drop(ideology_id: int, from_location: int, kind: int) -> void:
	_hover_niche = null
	_hover_id = -1
	_update_resonance(null, -1)
	_queue_links()
	if kind == 1:
		if from_location == 0:
			_command("equip", ideology_id)
		return
	if from_location != 1:
		_flash_hint("需先推行")
		return
	_request_promotion(ideology_id)


func _on_niche_hover(ideology_id: int, kind: int, entered: bool, niche: Control) -> void:
	var location := int((_states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if entered and kind == 1 and location == 0:
		_hover_niche = niche
		_hover_id = ideology_id
		_update_resonance(niche, ideology_id)
	elif _hover_niche == niche or not entered:
		_hover_niche = null
		_hover_id = -1
		_update_resonance(null, -1)
	_update_links()


func _can_drop_collection(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("ideology_card") \
		and int((data as Dictionary).get("location", 0)) == 1


func _drop_collection(_at_position: Vector2, data: Variant) -> void:
	_command("unequip", int((data as Dictionary).get("ideology_card", -1)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _hover_niche != null:
		_hover_niche = null
		_hover_id = -1
		_update_resonance(null, -1)
		_queue_links()


func _on_card_activated(ideology_id: int) -> void:
	# Keyboard / gamepad accept: same intent as the primary action button.
	var location := int((_states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if location == 0:
		_command("equip", ideology_id)
	elif location == 1:
		_command("unequip", ideology_id)


func _on_tab_changed(tab: int) -> void:
	_tab_school = "" if tab <= 0 else String(ArtScript.SCHOOL_ORDER[tab - 1])
	_signature = ""
	_rebuild_board()


func _on_sort_selected(index: int) -> void:
	_sort_mode = index
	_signature = ""
	_rebuild_board()


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
		_play_tear_in()
	else:
		_show_result(result)


func _dismiss_offer() -> void:
	_dismissed_generation = int(_snapshot.get("offer_generation", 0))
	if _player_controller != null and _player_controller.has_method("dismiss_ideology_offer"):
		_player_controller.dismiss_ideology_offer()
	_render_top()
	_rebuild_offer()


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
	if _promotion_dialog == null:
		return
	_pending_promotion_id = ideology_id
	_promotion_dialog.dialog_text = "将「%s」晋升为民族精神？晋升不可逆。" \
		% _display_name(_metadata.get(ideology_id, {}), ideology_id)
	_promotion_dialog.popup_centered()


func _confirm_promotion() -> void:
	if _pending_promotion_id < 0:
		return
	var ideology_id := _pending_promotion_id
	_pending_promotion_id = -1
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
		if _tear != null and _tear.coverage > 0.0:
			_play_tear_out()
	_render_top()
	_rebuild_offer()


func _show_result(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_flash_hint("明日生效")
	else:
		_flash_hint(CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。")))))


func _flash_hint(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint.visible = not text.is_empty()
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
		_offer.visible = false
		for index in 3:
			_choice(index).visible = false
		if not active:
			_chosen_generation = -1
		return
	_offer.visible = true
	var ids: PackedInt32Array = _snapshot.get("offer_ids", PackedInt32Array())
	var fresh := active and generation > _revealed_generation and not waiting
	if waiting and not fresh:
		# Draw submitted; the one-day settlement has not published yet.
		_offer_title.text = "抽取中…"
		for index in 3:
			var card := _choice(index)
			card.visible = true
			if ids.size() <= index:
				card.call("set_card", {"ideology_id": -1, "display_name": ""})
			card.call("set_face_up", false)
		_reroll_button.disabled = true
		_dismiss_button.disabled = true
		return
	_offer_title.text = "选择一条道路"
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
				"tooltip": String(view.get("tooltip", "")),
			})
	var reroll_cost := String(_presentation.get("reroll_cost_text", ""))
	_reroll_button.text = "重抽 · %s" % reroll_cost
	_reroll_button.disabled = not bool(_presentation.get("can_reroll", false))
	_reroll_button.tooltip_text = "花费 %s 理念点重抽" % reroll_cost
	_dismiss_button.disabled = false
	if fresh:
		_revealed_generation = generation
		# The offer stage sits above the deck table; bring it into view so a
		# scrolled-down collection never hides the reveal.
		if _scroll != null:
			_scroll.set_deferred("scroll_vertical", 0)
		_play_reveal(ids.size())
	else:
		for index in 3:
			_choice(index).call("set_face_up", true)


func _play_reveal(count: int) -> void:
	var mask := _unroll_mask.material as ShaderMaterial
	var had_tear := _tear.coverage > 0.0
	if reduce_motion or not is_visible_in_tree():
		mask.set_shader_parameter("reveal", 1.0)
		_tear.coverage = 0.0
		_tear.queue_redraw()
		for index in 3:
			var card := _choice(index)
			card.call("reset_motion")
			card.call("set_face_up", true)
		return
	_offer_anim_busy = true
	for index in 3:
		_choice(index).call("reset_motion")
		_choice(index).call("set_face_up", false)
	var tween := create_tween()
	if had_tear:
		tween.tween_method(_set_tear, 1.0, 0.0, 0.32).set_trans(Tween.TRANS_QUAD) \
			.set_ease(Tween.EASE_IN)
	else:
		mask.set_shader_parameter("reveal", 0.0)
		tween.tween_method(_set_unroll, 0.0, 1.0, 0.45) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_drop_cards.bind(count))
	tween.tween_interval(count * DROP_STAGGER + 0.36)
	for index in count:
		tween.tween_callback(_reveal_card.bind(index))
		tween.tween_interval(0.16)
	tween.tween_interval(0.3)
	tween.tween_callback(_finish_offer_animation)


func _reveal_card(index: int) -> void:
	var card := _choice(index)
	var flip: Tween = card.call("flip_to_face")
	var rarity := int((card.call("card_data") as Dictionary).get("rarity", 1))
	if rarity < 2:
		return
	flip.tween_callback(_reveal_flourish.bind(card, rarity))


## Rare cards get a gold-leaf sweep; legendary ones add ink, seal and confetti.
func _reveal_flourish(card: Control, rarity: int) -> void:
	card.call("play_gloss", 2 if rarity >= 3 else 1)
	if rarity < 3:
		return
	var rect := card.get_global_rect()
	_spawn_sprite(ArtScript.INK_SPLASH, rect.get_center(), Vector2(220, 220), 0.9, -0.2)
	_spawn_sprite(ArtScript.WAX_SEAL, rect.position + Vector2(rect.size.x - 22, 24),
		Vector2(52, 52), 1.4, 0.3, true)
	_spawn_burst(rect.get_center(), true)


func _set_unroll(value: float) -> void:
	(_unroll_mask.material as ShaderMaterial).set_shader_parameter("reveal", value)


func _drop_cards(count: int) -> void:
	for index in count:
		_choice(index).call("play_drop", index * DROP_STAGGER)


func _finish_offer_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		if _choice(index).visible:
			_choice(index).call("set_face_up", true)
	_rebuild_offer()


func _on_choice_input(event: InputEvent, index: int) -> void:
	# Single click selects the card for keyboard confirm; double click/accept
	# arrives through `activated`.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_choice(index).grab_focus()


func _on_choice_activated(_ideology_id: int, index: int) -> void:
	_choose_offer(index)


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
	if reduce_motion or not is_visible_in_tree():
		_rebuild_offer()
		return
	_offer_anim_busy = true
	var chosen := _choice(choice_index)
	chosen.call("stamp_punch")
	var rect := chosen.get_global_rect()
	_spawn_sprite(ArtScript.WAX_SEAL, rect.get_center(), Vector2(84, 84), 0.9, -0.15, true)
	_shake(4.0)
	for index in 3:
		if index != choice_index and _choice(index).visible:
			_choice(index).call("fold_away")
	var tween := create_tween()
	tween.tween_interval(0.42)
	tween.tween_callback(_fly_and_fold.bind(chosen))
	tween.tween_interval(0.5)
	tween.tween_callback(_finish_choose_animation)


func _fly_and_fold(chosen: Control) -> void:
	_fly_to_collection(chosen)
	chosen.call("fold_away", 0.12)


func _finish_choose_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		_choice(index).call("reset_motion")
	_rebuild_offer()


func _fly_to_collection(card: Control) -> void:
	var ghost := TextureRect.new()
	ghost.texture = card.call("frame_texture")
	ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ghost.stretch_mode = TextureRect.STRETCH_SCALE
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var from := card.get_global_rect()
	ghost.size = from.size
	ghost.pivot_offset = from.size * 0.5
	ghost.position = from.position - _fx.get_global_rect().position
	_fx.add_child(ghost)
	var target_rect := _collection_drop.get_global_rect()
	var target := Vector2(target_rect.get_center().x, target_rect.position.y + 30.0) \
		- _fx.get_global_rect().position - from.size * 0.5
	var tween := ghost.create_tween()
	tween.tween_property(ghost, "position", target, 0.46) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.parallel().tween_property(ghost, "scale", Vector2(0.35, 0.35), 0.46)
	tween.parallel().tween_property(ghost, "rotation", 0.25, 0.46)
	tween.tween_property(ghost, "modulate:a", 0.0, 0.12)
	tween.tween_callback(ghost.queue_free)


func _play_tear_in() -> void:
	if reduce_motion or not is_visible_in_tree():
		return
	_tear.seed_edges()
	var tween := create_tween()
	tween.tween_method(_set_tear, 0.0, 1.0, 0.34).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)


func _play_tear_out() -> void:
	var tween := create_tween()
	tween.tween_method(_set_tear, _tear.coverage, 0.0, 0.25)


func _set_tear(value: float) -> void:
	_tear.coverage = value
	_tear.queue_redraw()


# --- effects --------------------------------------------------------------

func _shake(amplitude: float) -> void:
	if _root == null:
		return
	var base := Vector2.ZERO
	var tween := create_tween()
	for offset in [Vector2(amplitude, 0), Vector2(-amplitude, 1), Vector2(amplitude * 0.6, -1),
			Vector2(-amplitude * 0.3, 0), base]:
		tween.tween_property(_root, "position", offset, 0.035)


func _spawn_sprite(path: String, global_center: Vector2, sprite_size: Vector2,
		life: float, rotation_rad: float, slam := false) -> void:
	var texture := ArtScript.texture(path)
	if texture == null or _fx == null:
		return
	var sprite := TextureRect.new()
	sprite.texture = texture
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.size = sprite_size
	sprite.pivot_offset = sprite_size * 0.5
	sprite.position = global_center - _fx.get_global_rect().position - sprite_size * 0.5
	sprite.rotation = rotation_rad
	_fx.add_child(sprite)
	var tween := sprite.create_tween()
	if slam:
		sprite.scale = Vector2(2.2, 2.2)
		sprite.modulate.a = 0.0
		tween.tween_property(sprite, "scale", Vector2.ONE, 0.16) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.parallel().tween_property(sprite, "modulate:a", 1.0, 0.1)
	else:
		sprite.scale = Vector2(0.4, 0.4)
		sprite.modulate.a = 0.85
		tween.tween_property(sprite, "scale", Vector2.ONE, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(life)
	tween.tween_property(sprite, "modulate:a", 0.0, 0.35)
	tween.tween_callback(sprite.queue_free)


func _spawn_burst(global_center: Vector2, large: bool) -> void:
	if _fx == null or reduce_motion:
		return
	var particles := CPUParticles2D.new()
	particles.texture = ArtScript.texture(ArtScript.PAPER_CONFETTI)
	particles.one_shot = true
	particles.amount = 26 if large else 14
	particles.lifetime = 1.1
	particles.explosiveness = 0.92
	particles.direction = Vector2(0, -1)
	particles.spread = 80.0
	particles.initial_velocity_min = 90.0
	particles.initial_velocity_max = 210.0 if large else 140.0
	particles.gravity = Vector2(0, 260)
	particles.angular_velocity_min = -240.0
	particles.angular_velocity_max = 240.0
	particles.scale_amount_min = 0.05
	particles.scale_amount_max = 0.11
	particles.position = global_center - _fx.get_global_rect().position
	_fx.add_child(particles)
	particles.emitting = true
	particles.finished.connect(particles.queue_free)


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
	if reduce_motion:
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
	var rows: Array = live.get("support", [])
	if direction < 0 or direction >= rows.size():
		return "民意不可用"
	var support: Dictionary = rows[direction]
	if not bool(support.get("available", false)):
		return "民意待发布"
	var label := "通过" if bool(support.get("allowed", false)) else "未通过"
	return "民意 %s %s / %s" % [label, _q16_signed(int(support.get("support_q16", 0))),
		_q16_signed(int(support.get("threshold_q16", 0)))]


func _support_tooltip(live: Dictionary, direction: int) -> String:
	var lines := PackedStringArray([_support_summary(live, direction)])
	var class_ids: PackedStringArray = _catalog.get("political_class_ids", PackedStringArray())
	for row in live.get("classes", []) as Array:
		var info := row as Dictionary
		var class_index := int(info.get("class_index", -1))
		var contributions: Array = info.get("contributions", [])
		var contribution := int(contributions[direction]) \
			if direction >= 0 and direction < contributions.size() else 0
		var class_label := String(class_ids[class_index]) \
			if class_index >= 0 and class_index < class_ids.size() else "阶层 %d" % class_index
		lines.append("%s：%+.2f（影响力 %d）" % [class_label,
			float(contribution) / Q16_ONE, int(info.get("influence", 0))])
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
	_signature = ""
	_explain_signature = ""
	_points_signature = ""
	_presentation = {}
	_snapshot = {}
	_offer_button.disabled = true
	_offer_button.text = "抽取"
	_hint.text = "载入中…" if loading and reason.is_empty() else (
		reason if not reason.is_empty() else "暂不可用")
	_hint.visible = true
	_offer.visible = false
	_point_scroll.call("set_points", 0, 65536, 0, false, true)
	_show_empty_state(true, {
		"empty_title": "载入中…" if loading else "暂不可用",
		"empty_detail": _hint.text,
	})


func _show_empty_state(visible_state: bool, presentation: Dictionary) -> void:
	if _empty == null:
		return
	_empty.visible = visible_state
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
		summaries.append(String(card.call("summary_text")))
	return summaries


func niche_count(kind: int) -> int:
	var host := _ideology_slots if kind == 1 else _spirit_slots
	return 0 if host == null else host.get_child_count()


func collection_count() -> int:
	return 0 if _collection == null else _collection.get_child_count()


func link_segment_count() -> int:
	return 0 if _link_layer == null else _link_layer.segments.size()


## Test hook: simulate a card drop onto a niche kind without a real drag.
func simulate_drop(ideology_id: int, from_location: int, kind: int) -> void:
	_on_niche_drop(ideology_id, from_location, kind)


# --- inner drawing helpers --------------------------------------------------

## Red silk threads between equipped cards of an active named synergy; dashed
## while a drag would complete one.
class LinkLayer:
	extends Control
	var segments: Array = []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var thread := Color(0.66, 0.15, 0.09, 0.85)
		for segment in segments:
			var a: Vector2 = segment[0]
			var b: Vector2 = segment[1]
			var sag := Vector2(0, 18)
			var points := PackedVector2Array()
			for step in 13:
				var t := float(step) / 12.0
				points.append(a.lerp(b, t) + sag * sin(t * PI))
			if bool(segment[2]):
				for index in range(0, points.size() - 1, 2):
					draw_line(points[index], points[index + 1], Color(thread, 0.6), 2.0, true)
			else:
				draw_polyline(points, thread, 2.5, true)
				var mid := points[6]
				draw_circle(mid, 5.0, thread)
				var font := ThemeDB.fallback_font
				draw_string(font, mid + Vector2(-40, -9), String(segment[3]),
					HORIZONTAL_ALIGNMENT_CENTER, 80, 11, Color(0.45, 0.10, 0.06))


## Torn paper sheet that sweeps across the offer stage during a reroll.
class TornPaper:
	extends Control
	var coverage := 0.0
	var _jag := PackedFloat32Array()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		seed_edges()

	func seed_edges() -> void:
		_jag.clear()
		var rng := RandomNumberGenerator.new()
		rng.seed = Time.get_ticks_usec()
		for _i in 24:
			_jag.append(rng.randf_range(-14.0, 14.0))

	func _draw() -> void:
		if coverage <= 0.0:
			return
		var edge_x := size.x * coverage
		var polygon := PackedVector2Array([Vector2(0, 0)])
		for index in _jag.size():
			var y := size.y * float(index) / float(_jag.size() - 1)
			polygon.append(Vector2(edge_x + _jag[index], y))
		polygon.append(Vector2(0, size.y))
		draw_colored_polygon(polygon, Color(0.93, 0.87, 0.74, 0.97))
		var edge := PackedVector2Array()
		for index in range(1, polygon.size() - 1):
			edge.append(polygon[index])
		draw_polyline(edge, Color(0.55, 0.40, 0.24, 0.9), 2.0, true)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(maxf(12.0, edge_x * 0.5 - 60.0), size.y * 0.5),
			"", HORIZONTAL_ALIGNMENT_LEFT, 160, 18, Color(0.40, 0.25, 0.14, coverage))


## One school emblem with its 2- and 4-card resonance pips.
class ResonanceEmblem:
	extends VBoxContainer
	var school_id := ""
	var _icon: TextureRect
	var _count: Label
	var _pips: HBoxContainer

	func configure(school: String) -> void:
		school_id = school
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 1)
		custom_minimum_size = Vector2(78, 0)
		_icon = TextureRect.new()
		_icon.texture = IdeologyArt.emblem_for(school)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.custom_minimum_size = Vector2(40, 40)
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
		_count = IdeologyArt.label(IdeologyArt.school_name(school), 11,
			IdeologyArt.school_color(school))
		add_child(_count)
		_pips = HBoxContainer.new()
		_pips.alignment = BoxContainer.ALIGNMENT_CENTER
		_pips.add_theme_constant_override("separation", 4)
		_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pips)

	func set_compact(compact: bool) -> void:
		_icon.custom_minimum_size = Vector2(30, 30) if compact else Vector2(40, 40)
		custom_minimum_size.x = 64 if compact else 78

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
			pip.custom_minimum_size = Vector2(12, 12)
			pip.rotation = 0.0
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
		tween.tween_property(self, "scale", Vector2(1.25, 1.25), 0.1)
		tween.tween_property(self, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
