extends Control
class_name IdeologyWorkspace

# A cold-path, Facade-only presentation of the native ideology authority. Rows
# are rebuilt only when the compact native snapshot changes; no UI node keeps a
# second mutable ideology model.

const Q16_ONE := 65536.0
const IdeaRowScene := preload("res://scenes/ui/ideology_idea_row.tscn")
const OfferChoiceScene := preload("res://scenes/ui/ideology_offer_choice.tscn")

var _facade = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _sequence := 300000
var _signature := ""

var _points: Label
var _slots: Label
var _spirits: Label
var _hint: Label
var _offer_button: Button
var _rows: VBoxContainer
var _empty: Label
var _offer: PanelContainer
var _offer_cards: HBoxContainer


func _ready() -> void:
	if _rows != null:
		return
	_points = get_node_or_null("Root/Status/Points") as Label
	_slots = get_node_or_null("Root/Status/Slots") as Label
	_spirits = get_node_or_null("Root/Status/Spirits") as Label
	_hint = get_node_or_null("Root/Actions/Hint") as Label
	_offer_button = get_node_or_null("Root/Actions/OpenOffer") as Button
	_rows = get_node_or_null("Root/Scroll/Rows") as VBoxContainer
	_empty = get_node_or_null("Root/Scroll/Rows/EmptyLabel") as Label
	_offer = get_node_or_null("Root/Offer") as PanelContainer
	_offer_cards = get_node_or_null("Root/Offer/Cards") as HBoxContainer
	if _points == null or _slots == null or _spirits == null or _hint == null \
			or _offer_button == null or _rows == null or _offer == null or _offer_cards == null:
		push_error("IdeologyWorkspace 必须由 ideology_workspace.tscn 实例化。")
		return
	_offer_button.theme_type_variation = &"PKPrimaryButton"
	_offer_button.pressed.connect(_open_offer)


func set_model(model: Dictionary) -> void:
	if _rows == null:
		_ready()
	_apply_model(model)


func refresh_model(model: Dictionary) -> void:
	if _rows == null:
		return
	_apply_model(model)


func set_compact(compact: bool) -> void:
	if _offer_cards != null:
		_offer_cards.visible = not compact or bool(_snapshot.get("offer_active", false))


func _apply_model(model: Dictionary) -> void:
	var ideology: Dictionary = model.get("ideology", {})
	_facade = ideology.get("facade")
	_country_handle = int(model.get("country_handle", 0))
	_current_day = int(model.get("current_day", 0))
	_catalog = ideology.get("catalog", {})
	_snapshot = ideology.get("snapshot", {})
	if not bool(ideology.get("available", false)):
		_hint.text = String(ideology.get("reason", "理念暂不可用。"))
		_offer_button.disabled = true
		return
	_points.text = "理念点 %s" % _q16(int(_snapshot.get("ideology_points_q16", 0)))
	_slots.text = "意识形态槽 %d / %d" % [int(_snapshot.get("ideology_slots_used", 0)),
		int(_snapshot.get("ideology_slots_capacity", 0))]
	_spirits.text = "民族精神槽 %d / %d" % [int(_snapshot.get("national_spirit_slots_used", 0)),
		int(_snapshot.get("national_spirit_slots_capacity", 0))]
	_offer_button.disabled = bool(_snapshot.get("offer_active", false))
	_offer_button.text = "三选一已锁定" if bool(_snapshot.get("offer_active", false)) else "抽取理念（三选一）"
	var signature := "%s|%s|%s|%s" % [_snapshot.get("known_ids", PackedInt32Array()),
		_snapshot.get("understanding_q16", PackedInt64Array()), _snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray())]
	if signature != _signature:
		_signature = signature
		_rebuild_rows()
	_rebuild_offer()


func _rebuild_rows() -> void:
	for child in _rows.get_children():
		if child == _empty:
			continue
		child.queue_free()
	var metadata := {}
	for row in _catalog.get("ideologies", []) as Array:
		metadata[int((row as Dictionary).get("dense_id", -1))] = row
	var state_by_id := {}
	var ids: PackedInt32Array = _snapshot.get("idea_ids", PackedInt32Array())
	var understanding: PackedInt64Array = _snapshot.get("understanding_q16", PackedInt64Array())
	var levels: PackedInt32Array = _snapshot.get("levels", PackedInt32Array())
	var locations: PackedInt32Array = _snapshot.get("locations", PackedInt32Array())
	var pending: PackedByteArray = _snapshot.get("transition_pending", PackedByteArray())
	for index in range(ids.size()):
		state_by_id[int(ids[index])] = {
			"understanding": int(understanding[index]) if index < understanding.size() else 0,
			"level": int(levels[index]) if index < levels.size() else -1,
			"location": int(locations[index]) if index < locations.size() else 0,
			"pending": index < pending.size() and pending[index] != 0,
		}
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	if _empty != null:
		_empty.visible = known.is_empty()
	for ideology_id in known:
		var state: Dictionary = state_by_id.get(int(ideology_id), {})
		_rows.add_child(_row(int(ideology_id), metadata.get(int(ideology_id), {}), state))


func _row(ideology_id: int, metadata: Dictionary, state: Dictionary) -> Control:
	var card := IdeaRowScene.instantiate() as PanelContainer
	var name_label := card.get_node("Body/Title/Name") as Label
	name_label.text = _display_name(metadata, ideology_id)
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var badges := card.get_node("Body/Title/Slots") as BadgeRow
	var slot_text: String = "正在生效"
	if not pending:
		match clampi(location, 0, 2):
			1:
				slot_text = "意识形态"
			2:
				slot_text = "民族精神"
			_:
				slot_text = "未装备"
	badges.set_badges([{
		"text": slot_text,
		"accent": UITokens.WARN if pending else (UITokens.ACCENT if location > 0 else UITokens.TEXT_MUTED),
	}])
	var explanation: Dictionary = _facade.explain_ideology(_country_handle, ideology_id) if _facade != null else {}
	var level := int(state.get("level", -1))
	var thresholds: PackedInt64Array = explanation.get("thresholds_q16", PackedInt64Array())
	var amount := int(state.get("understanding", 0))
	var next := int(thresholds[level + 1]) if level + 1 < thresholds.size() else amount
	var ratio := 1.0 if next <= 0 else clampf(float(amount) / float(maxi(1, next)), 0.0, 1.0)
	var gauge := card.get_node("Body/Gauge") as GaugeBar
	gauge.set_data("理解度", ratio, "", "", UITokens.ACCENT, -1.0,
		"已满级" if level + 1 >= thresholds.size() else "下一级 %s" % _q16(next),
		_q16(amount))
	var detail := card.get_node("Body/Detail") as Label
	detail.text = "等级 %d" % maxi(0, level + 1)
	detail.tooltip_text = String(metadata.get("detail_key", ""))
	var equip := card.get_node("Body/Actions/Equip") as Button
	var unequip := card.get_node("Body/Actions/Unequip") as Button
	var promote := card.get_node("Body/Actions/Promote") as Button
	equip.visible = location == 0
	equip.disabled = pending
	equip.pressed.connect(func() -> void: _command("equip", ideology_id))
	unequip.visible = location == 1
	unequip.disabled = pending
	unequip.pressed.connect(func() -> void: _command("unequip", ideology_id))
	var spirit_min := int(explanation.get("min_spirit_level", 99))
	promote.visible = location != 2
	promote.disabled = pending or level < spirit_min
	promote.pressed.connect(func() -> void: _command("promote", ideology_id))
	return card


func _display_name(metadata: Dictionary, ideology_id: int) -> String:
	var display := String(metadata.get("display_name", ""))
	if not display.is_empty():
		return display
	var name_key := String(metadata.get("name_key", ""))
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	var stable_id := String(metadata.get("id", ""))
	if not stable_id.is_empty():
		return stable_id
	return "理念 %d" % ideology_id


func _open_offer() -> void:
	if _facade == null:
		return
	var result: Dictionary = _facade.request_offer(_country_handle, _effective_day(), _next_sequence())
	_show_result(result)


func _command(kind: String, ideology_id: int) -> void:
	if _facade == null:
		return
	var result: Dictionary = {}
	match kind:
		"equip": result = _facade.equip(_country_handle, ideology_id, _effective_day(), _next_sequence())
		"unequip": result = _facade.unequip(_country_handle, ideology_id, _effective_day(), _next_sequence())
		"promote": result = _facade.promote(_country_handle, ideology_id, _effective_day(), _next_sequence())
	_show_result(result)


func _rebuild_offer() -> void:
	for child in _offer_cards.get_children():
		child.queue_free()
	var active := bool(_snapshot.get("offer_active", false))
	_offer.visible = active
	if not active:
		return
	var metadata := {}
	for row in _catalog.get("ideologies", []) as Array:
		metadata[int((row as Dictionary).get("dense_id", -1))] = row
	var ids: PackedInt32Array = _snapshot.get("offer_ids", PackedInt32Array())
	for index in range(ids.size()):
		var button := OfferChoiceScene.instantiate() as Button
		var info: Dictionary = metadata.get(int(ids[index]), {})
		button.text = _display_name(info, int(ids[index]))
		button.tooltip_text = String(info.get("detail_key", ""))
		button.pressed.connect(func() -> void: _choose_offer(index))
		_offer_cards.add_child(button)


func _choose_offer(choice_index: int) -> void:
	if _facade == null:
		return
	var result: Dictionary = _facade.choose_offer(_country_handle,
		int(_snapshot.get("offer_generation", 0)), choice_index, _effective_day(), _next_sequence())
	_show_result(result)


func _show_result(result: Dictionary) -> void:
	_hint.text = "将于明日生效。" if bool(result.get("ok", false)) \
		else String(result.get("reason", "理念命令被拒绝。"))


func _effective_day() -> int:
	return maxi(0, _current_day + 1)


func _next_sequence() -> int:
	_sequence += 1
	return _sequence


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)
