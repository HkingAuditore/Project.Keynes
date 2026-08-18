extends Control
class_name IdeologyWorkspace

# A cold-path, Facade-only presentation of the native ideology authority. Rows
# are rebuilt only when the compact native snapshot changes; no UI node keeps a
# second mutable ideology model.

const Q16_ONE := 65536.0
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const IdeaRowScene := preload("res://scenes/ui/ideology_idea_row.tscn")
const OfferChoiceScene := preload("res://scenes/ui/ideology_offer_choice.tscn")

var _facade = null
var _player_controller = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _live_explain: Dictionary = {}
var _live_by_id := {}
var _signature := ""
var _explain_signature := ""
var _pending_promotion_id := -1

var _points: Label
var _slots: Label
var _spirits: Label
var _hint: Label
var _offer_button: Button
var _rows: VBoxContainer
var _empty: Label
var _offer: PanelContainer
var _offer_cards: HBoxContainer
var _promotion_dialog: ConfirmationDialog


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
	_promotion_dialog = ConfirmationDialog.new()
	_promotion_dialog.title = "确认晋升民族精神"
	_promotion_dialog.dialog_text = "民族精神晋升不可逆，并会占用民族精神槽位。"
	_promotion_dialog.ok_button_text = "确认晋升"
	_promotion_dialog.confirmed.connect(_confirm_promotion)
	add_child(_promotion_dialog)


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

func set_player_controller(controller) -> void:
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var old_callback := Callable(self, "_on_player_command_settled")
		if _player_controller.command_settled.is_connected(old_callback):
			_player_controller.command_settled.disconnect(old_callback)
	_player_controller = controller
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var callback := Callable(self, "_on_player_command_settled")
		if not _player_controller.command_settled.is_connected(callback):
			_player_controller.command_settled.connect(callback)


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
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	var explain_signature := "%d|%d|%s|%s|%s|%s" % [
		_country_handle, int(_snapshot.get("support_revision", 0)), known,
		_snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("locations", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray())]
	if explain_signature != _explain_signature:
		_explain_signature = explain_signature
		_refresh_live_explain(known)
	var signature := "%s|%s|%s|%s|%d" % [known,
		_snapshot.get("understanding_q16", PackedInt64Array()), _snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray()),
		int(_live_explain.get("support_revision", 0))]
	if signature != _signature:
		_signature = signature
		_rebuild_rows()
	_rebuild_offer()


func _refresh_live_explain(known: PackedInt32Array) -> void:
	_live_explain = _facade.explain_ideologies(_country_handle, known) \
		if _facade != null else {}
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
	var synergy_offsets: PackedInt32Array = _live_explain.get("affected_synergy_offsets", PackedInt32Array())
	var synergy_ids: PackedInt32Array = _live_explain.get("affected_synergy_ids", PackedInt32Array())
	var synergy_current: PackedByteArray = _live_explain.get("current_synergy_active", PackedByteArray())
	var synergy_equip: PackedByteArray = _live_explain.get("equip_synergy_active", PackedByteArray())
	var synergy_unequip: PackedByteArray = _live_explain.get("unequip_synergy_active", PackedByteArray())
	var synergy_promote: PackedByteArray = _live_explain.get("promote_synergy_active", PackedByteArray())
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
		var stance_end := int(stance_offsets[index + 1]) if index + 1 < stance_offsets.size() else stance_begin
		for row in range(stance_begin, stance_end):
			class_rows.append({
				"class_index": int(stance_classes[row]),
				"influence": int(influence[row]),
				"contributions": [
					int(adopt_contributions[row]),
					int(repeal_contributions[row]),
					int(promote_contributions[row]),
				],
			})
		var synergy_rows: Array[Dictionary] = []
		var synergy_begin := int(synergy_offsets[index]) if index < synergy_offsets.size() else 0
		var synergy_end := int(synergy_offsets[index + 1]) if index + 1 < synergy_offsets.size() else synergy_begin
		for row in range(synergy_begin, synergy_end):
			synergy_rows.append({
				"id": int(synergy_ids[row]),
				"current": row < synergy_current.size() and synergy_current[row] != 0,
				"equip": row < synergy_equip.size() and synergy_equip[row] != 0,
				"unequip": row < synergy_unequip.size() and synergy_unequip[row] != 0,
				"promote": row < synergy_promote.size() and synergy_promote[row] != 0,
			})
		_live_by_id[int(ids[index])] = {
			"support": support_rows,
			"classes": class_rows,
			"synergies": synergy_rows,
			"equip_allowed": index < equip_allowed.size() and equip_allowed[index] != 0,
			"unequip_allowed": index < unequip_allowed.size() and unequip_allowed[index] != 0,
			"promote_allowed": index < promote_allowed.size() and promote_allowed[index] != 0,
		}


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
		_rows.add_child(_row(int(ideology_id), metadata.get(int(ideology_id), {}),
			state, _live_by_id.get(int(ideology_id), {})))


func _row(ideology_id: int, metadata: Dictionary, state: Dictionary,
		live: Dictionary) -> Control:
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
	var level := int(state.get("level", -1))
	var thresholds: PackedInt64Array = metadata.get("level_thresholds_q16", PackedInt64Array())
	var amount := int(state.get("understanding", 0))
	var next := int(thresholds[level + 1]) if level + 1 < thresholds.size() else amount
	var ratio := 1.0 if next <= 0 else clampf(float(amount) / float(maxi(1, next)), 0.0, 1.0)
	var gauge := card.get_node("Body/Gauge") as GaugeBar
	gauge.set_data("理解度", ratio, "", "", UITokens.ACCENT, -1.0,
		"已满级" if level + 1 >= thresholds.size() else "下一级 %s" % _q16(next),
		_q16(amount))
	var detail := card.get_node("Body/Detail") as Label
	var direction := 0 if location == 0 else 1
	detail.text = "等级 %d · %s" % [maxi(0, level + 1),
		_support_summary(live, direction)]
	detail.tooltip_text = _support_tooltip(metadata, live, direction)
	var equip := card.get_node("Body/Actions/Equip") as Button
	var unequip := card.get_node("Body/Actions/Unequip") as Button
	var promote := card.get_node("Body/Actions/Promote") as Button
	equip.visible = location == 0
	equip.disabled = pending or not bool(live.get("equip_allowed", false))
	equip.pressed.connect(func() -> void: _command("equip", ideology_id))
	unequip.visible = location == 1
	unequip.disabled = pending or not bool(live.get("unequip_allowed", false))
	unequip.pressed.connect(func() -> void: _command("unequip", ideology_id))
	var spirit_min := int(metadata.get("min_spirit_level", 99))
	promote.visible = location == 1
	promote.disabled = pending or level < spirit_min \
		or not bool(live.get("promote_allowed", false))
	promote.pressed.connect(func() -> void: _request_promotion(ideology_id))
	return card


func _support_summary(live: Dictionary, direction: int) -> String:
	var rows: Array = live.get("support", [])
	if direction < 0 or direction >= rows.size():
		return "民意不可用"
	var support: Dictionary = rows[direction]
	if not bool(support.get("available", false)):
		return "民意待发布"
	var label := "通过" if bool(support.get("allowed", false)) else "未通过"
	return "民意 %s %s / %s" % [
		label,
		_q16_signed(int(support.get("support_q16", 0))),
		_q16_signed(int(support.get("threshold_q16", 0))),
	]


func _support_tooltip(metadata: Dictionary, live: Dictionary,
		direction: int) -> String:
	var lines: PackedStringArray = PackedStringArray([
		String(metadata.get("detail_key", "")),
		_support_summary(live, direction),
	])
	var class_ids: PackedStringArray = _catalog.get(
		"political_class_ids", PackedStringArray())
	for row in live.get("classes", []) as Array:
		var info := row as Dictionary
		var class_index := int(info.get("class_index", -1))
		var contributions: Array = info.get("contributions", [])
		var contribution := int(contributions[direction]) \
			if direction >= 0 and direction < contributions.size() else 0
		var class_label := String(class_ids[class_index]) \
			if class_index >= 0 and class_index < class_ids.size() \
			else "阶层 %d" % class_index
		lines.append("%s：%+.2f（影响力 %d）" % [
			class_label, float(contribution) / Q16_ONE,
			int(info.get("influence", 0)),
		])
	var gained: PackedStringArray = PackedStringArray()
	var lost: PackedStringArray = PackedStringArray()
	var expected_key: String = ["equip", "unequip", "promote"][
		clampi(direction, 0, 2)]
	for row in live.get("synergies", []) as Array:
		var synergy := row as Dictionary
		var current := bool(synergy.get("current", false))
		var expected := bool(synergy.get(expected_key, current))
		if expected and not current:
			gained.append(_synergy_name(int(synergy.get("id", -1))))
		elif current and not expected:
			lost.append(_synergy_name(int(synergy.get("id", -1))))
	if not gained.is_empty():
		lines.append("预计获得联动：%s" % "、".join(gained))
	if not lost.is_empty():
		lines.append("预计失去联动：%s" % "、".join(lost))
	return "\n".join(lines)


func _synergy_name(synergy_id: int) -> String:
	for row in _catalog.get("synergies", []) as Array:
		var metadata := row as Dictionary
		if int(metadata.get("dense_id", -1)) == synergy_id:
			return String(metadata.get("id", "联动 %d" % synergy_id))
	return "联动 %d" % synergy_id


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
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	_show_result(result)


func _command(kind: String, ideology_id: int) -> void:
	if _player_controller == null:
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
		PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	]:
		return
	_hint.text = "理念命令已生效。" if bool(result.get("ok", false)) \
		else String(result.get("reason", "理念命令被拒绝。"))


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
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE, {
			"offer_generation": int(_snapshot.get("offer_generation", 0)),
			"choice_index": choice_index,
		})
	_show_result(result)


func _show_result(result: Dictionary) -> void:
	_hint.text = "将于明日生效。" if bool(result.get("ok", false)) \
		else String(result.get("reason", "理念命令被拒绝。"))


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)


func _q16_signed(value: int) -> String:
	return "%+.2f" % (float(value) / Q16_ONE)
