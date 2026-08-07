extends Control
class_name IdeologyWorkspace

# A cold-path, Facade-only presentation of the native ideology authority. Rows
# are rebuilt only when the compact native snapshot changes; no UI node keeps a
# second mutable ideology model.

const Q16_ONE := 65536.0

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
	_offer = get_node_or_null("Root/Offer") as PanelContainer
	_offer_cards = get_node_or_null("Root/Offer/Cards") as HBoxContainer
	if _points == null or _slots == null or _spirits == null or _hint == null \
			or _offer_button == null or _rows == null or _offer == null or _offer_cards == null:
		push_error("IdeologyWorkspace 必须由 ideology_workspace.tscn 实例化。")
		return
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
		_hint.text = String(ideology.get("reason", "理念运行时不可用。"))
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
	for ideology_id in known:
		var state: Dictionary = state_by_id.get(int(ideology_id), {})
		_rows.add_child(_row(int(ideology_id), metadata.get(int(ideology_id), {}), state))
	if known.is_empty():
		var empty := Label.new()
		empty.text = "尚未发现理念。通过条件、事件或理念点抽取获得。"
		empty.theme_type_variation = &"PKMutedLabel"
		_rows.add_child(empty)


func _row(ideology_id: int, metadata: Dictionary, state: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = &"PKInsetPanel"
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	card.add_child(body)
	var title := HBoxContainer.new()
	body.add_child(title)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text = String(metadata.get("name_key", metadata.get("id", "理念")))
	name_label.theme_type_variation = &"PKSectionTitle"
	title.add_child(name_label)
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var status := Label.new()
	status.text = "正在生效/替换" if pending else ["未装备", "意识形态", "民族精神"][clampi(location, 0, 2)]
	status.theme_type_variation = &"PKMutedLabel"
	title.add_child(status)
	var explanation: Dictionary = _facade.explain_ideology(_country_handle, ideology_id) if _facade != null else {}
	var level := int(state.get("level", -1))
	var thresholds: PackedInt64Array = explanation.get("thresholds_q16", PackedInt64Array())
	var amount := int(state.get("understanding", 0))
	var next := int(thresholds[level + 1]) if level + 1 < thresholds.size() else amount
	var progress := ProgressBar.new()
	progress.show_percentage = false
	progress.max_value = maxf(1.0, float(next))
	progress.value = minf(float(amount), progress.max_value)
	body.add_child(progress)
	var detail := Label.new()
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.text = "等级 %d  ·  理解度 %s%s" % [maxi(0, level + 1), _q16(amount),
		"  ·  已满级" if level + 1 >= thresholds.size() else "  ·  下一级 %s" % _q16(next)]
	detail.tooltip_text = String(metadata.get("detail_key", ""))
	detail.theme_type_variation = &"PKMutedLabel"
	body.add_child(detail)
	var actions := HBoxContainer.new()
	body.add_child(actions)
	if location == 0:
		_add_action(actions, "装备", func() -> void: _command("equip", ideology_id), pending)
	elif location == 1:
		_add_action(actions, "卸下", func() -> void: _command("unequip", ideology_id), pending)
	var spirit_min := int(explanation.get("min_spirit_level", 99))
	if location != 2:
		_add_action(actions, "晋升民族精神", func() -> void: _command("promote", ideology_id),
			pending or level < spirit_min)
	return card


func _add_action(host: HBoxContainer, label: String, callback: Callable, disabled: bool) -> void:
	var button := Button.new()
	button.text = label
	button.disabled = disabled
	button.pressed.connect(callback)
	host.add_child(button)


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
		var button := Button.new()
		var info: Dictionary = metadata.get(int(ids[index]), {})
		button.text = String(info.get("name_key", "理念 %d" % int(ids[index])))
		button.custom_minimum_size = Vector2(150, 70)
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
	_hint.text = "命令已排入下一安全边界。" if bool(result.get("ok", false)) \
		else String(result.get("reason", "理念命令被拒绝。"))


func _effective_day() -> int:
	return maxi(0, _current_day + 1)


func _next_sequence() -> int:
	_sequence += 1
	return _sequence


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)
