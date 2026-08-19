extends Control
class_name IdeologyWorkspace

# A cold-path, Facade-only presentation of the native ideology authority. Rows
# are rebuilt only when the compact native snapshot changes; no UI node keeps a
# second mutable ideology model.

const Q16_ONE := 65536.0
const CARD_SIZE := Vector2(150.0, 72.0)
const CARD_SIZE_COMPACT := Vector2(104.0, 56.0)
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const IdeaRowScene := preload("res://scenes/ui/ideology_idea_row.tscn")

var _facade = null
var _player_controller = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _presentation: Dictionary = {}
var _live_explain: Dictionary = {}
var _live_by_id := {}
var _signature := ""
var _explain_signature := ""
var _pending_promotion_id := -1
var _compact := false

var _points_card: MetricCard
var _slots_card: MetricCard
var _spirits_card: MetricCard
var _hint: Label
var _offer_button: Button
var _empty: PanelContainer
var _empty_icon: IconBadge
var _empty_title: Label
var _empty_detail: Label
var _empty_insights: InsightList
var _offer: PanelContainer
var _choice_0: PanelContainer
var _choice_1: PanelContainer
var _choice_2: PanelContainer
var _collection: VBoxContainer
var _promotion_dialog: ConfirmationDialog


func _ready() -> void:
	_bind_nodes()
	if _empty_icon != null:
		_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	_bind_idle_metrics()


func _bind_nodes() -> void:
	if _offer_button != null:
		return
	_points_card = %PointsCard
	_slots_card = %SlotsCard
	_spirits_card = %SpiritsCard
	_hint = %Hint
	_offer_button = %OpenOffer
	_empty = %EmptyState
	_empty_icon = %EmptyIcon
	_empty_title = %EmptyTitle
	_empty_detail = %EmptyDetail
	_empty_insights = %EmptyInsights
	_offer = %Offer
	_choice_0 = %Choice0
	_choice_1 = %Choice1
	_choice_2 = %Choice2
	_collection = %Collection
	_promotion_dialog = %PromotionDialog


func set_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func refresh_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func set_compact(compact: bool) -> void:
	_compact = compact
	_bind_nodes()
	if _points_card == null:
		return
	_points_card.set_compact(compact)
	_points_card.custom_minimum_size = CARD_SIZE_COMPACT if compact else CARD_SIZE
	_slots_card.set_compact(compact)
	_slots_card.custom_minimum_size = CARD_SIZE_COMPACT if compact else CARD_SIZE
	_spirits_card.set_compact(compact)
	_spirits_card.custom_minimum_size = CARD_SIZE_COMPACT if compact else CARD_SIZE

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
	if ideology.is_empty() or not bool(ideology.get("available", false)):
		var raw_reason := String(ideology.get("reason", model.get("reason", "")))
		var loading := ideology.is_empty() and not bool(model.get("available", false)) \
			and (raw_reason.is_empty() or raw_reason == "正在载入已提交数据")
		_show_shell(CountryViewModel.ideology_player_reason(raw_reason), loading)
		return
	_presentation = ideology.get("presentation", {})
	if _presentation.is_empty():
		_presentation = CountryViewModel.present_ideology(_snapshot, _catalog)
	_render_metrics(_presentation)
	_offer_button.disabled = not bool(_presentation.get("can_open_offer", false))
	_offer_button.text = "三选一已锁定" if bool(_presentation.get("offer_active", false)) \
		else "抽取理念（三选一）"
	_offer_button.tooltip_text = "抽取消耗 %s 理念点。" % String(
		_presentation.get("offer_cost_text", "1.00"))
	_hint.text = String(_presentation.get("offer_hint", ""))
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
	_show_empty_state(bool(_presentation.get("empty", known.is_empty())),
		_presentation)


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
	_show_empty_state(known.is_empty() and not bool(_snapshot.get("offer_active", false)),
		_presentation)
	_sync_collection(known.size())
	for index in known.size():
		var ideology_id := int(known[index])
		var card := _collection.get_child(index)
		if card.has_method("set_row"):
			card.call("set_row", _row_data(ideology_id, metadata.get(ideology_id, {}),
				state_by_id.get(ideology_id, {}), _live_by_id.get(ideology_id, {})))


func _sync_collection(count: int) -> void:
	while _collection.get_child_count() > count:
		var child := _collection.get_child(_collection.get_child_count() - 1)
		_collection.remove_child(child)
		child.queue_free()
	while _collection.get_child_count() < count:
		var card := IdeaRowScene.instantiate() as PanelContainer
		card.connect("equip_requested", _on_idea_equip)
		card.connect("unequip_requested", _on_idea_unequip)
		card.connect("promote_requested", _request_promotion)
		_collection.add_child(card)


func _row_data(ideology_id: int, metadata: Dictionary, state: Dictionary,
		live: Dictionary) -> Dictionary:
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var slot_text := "正在生效"
	if not pending:
		match clampi(location, 0, 2):
			1:
				slot_text = "意识形态"
			2:
				slot_text = "民族精神"
			_:
				slot_text = "未装备"
	var level := int(state.get("level", -1))
	var thresholds: PackedInt64Array = metadata.get("level_thresholds_q16", PackedInt64Array())
	var amount := int(state.get("understanding", 0))
	var next := int(thresholds[level + 1]) if level + 1 < thresholds.size() else amount
	var ratio := 1.0 if next <= 0 else clampf(float(amount) / float(maxi(1, next)), 0.0, 1.0)
	var card_view := CountryViewModel.present_ideology_card(metadata, maxi(0, level))
	var direction := 0 if location == 0 else 1
	var spirit_min := int(metadata.get("min_spirit_level", 99))
	return {
		"ideology_id": ideology_id,
		"display_name": _display_name(metadata, ideology_id),
		"slot_badges": [{
			"text": slot_text,
			"accent": UITokens.WARN if pending else (
				UITokens.ACCENT if location > 0 else UITokens.TEXT_MUTED),
		}],
		"gauge_title": "理解度",
		"gauge_ratio": ratio,
		"gauge_accent": UITokens.ACCENT,
		"gauge_subtitle": "已满级" if level + 1 >= thresholds.size() else "下一级 %s" % _q16(next),
		"gauge_value": _q16(amount),
		"effects": card_view.get("effects", []),
		"notes": card_view.get("badges", []),
		"detail": "等级 %d · %s" % [maxi(0, level + 1), _support_summary(live, direction)],
		"tooltip": "\n".join(PackedStringArray([
			String(card_view.get("summary", "")),
			_support_tooltip(metadata, live, direction),
		])),
		"equip_visible": location == 0,
		"equip_disabled": pending or not bool(live.get("equip_allowed", false)),
		"unequip_visible": location == 1,
		"unequip_disabled": pending or not bool(live.get("unequip_allowed", false)),
		"promote_visible": location == 1,
		"promote_disabled": pending or level < spirit_min \
			or not bool(live.get("promote_allowed", false)),
	}


func _on_idea_equip(ideology_id: int) -> void:
	_command("equip", ideology_id)


func _on_idea_unequip(ideology_id: int) -> void:
	_command("unequip", ideology_id)


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
			var display := String(metadata.get("display_name", ""))
			return display if not display.is_empty() else String(
				metadata.get("id", "联动 %d" % synergy_id))
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
		else CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。"))))


func _rebuild_offer() -> void:
	var active := bool(_snapshot.get("offer_active", false))
	_offer.visible = active
	var cards: Array[PanelContainer] = [_choice_0, _choice_1, _choice_2]
	if not active:
		for card in cards:
			card.visible = false
		return
	var metadata := {}
	for row in _catalog.get("ideologies", []) as Array:
		metadata[int((row as Dictionary).get("dense_id", -1))] = row
	var ids: PackedInt32Array = _snapshot.get("offer_ids", PackedInt32Array())
	for index in cards.size():
		var card := cards[index]
		var show := index < ids.size()
		card.visible = show
		if not show or not card.has_method("set_card"):
			continue
		card.call("set_card", CountryViewModel.present_ideology_card(
			metadata.get(int(ids[index]), {}), 0))


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
		else CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。"))))


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)


func _q16_signed(value: int) -> String:
	return "%+.2f" % (float(value) / Q16_ONE)


func _bind_idle_metrics() -> void:
	_render_metrics({
		"points_text": "—",
		"slots_used": 0,
		"slots_capacity": 0,
		"spirits_used": 0,
		"spirits_capacity": 0,
	})


func _show_shell(reason: String, loading: bool) -> void:
	_signature = ""
	_explain_signature = ""
	_presentation = {}
	_offer_button.disabled = true
	_offer_button.text = "抽取理念（三选一）"
	_hint.text = "正在整理内阁档案。" if loading and reason.is_empty() else (
		reason if not reason.is_empty() else "理念事务暂不可用。")
	_offer.visible = false
	_bind_idle_metrics()
	_show_empty_state(true, {
		"empty_title": "正在整理内阁档案" if loading else "理念事务暂不可用",
		"empty_detail": _hint.text,
		"empty_insights": [],
	})


func _render_metrics(presentation: Dictionary) -> void:
	var points_text := String(presentation.get("points_text", "—"))
	var slots_used := int(presentation.get("slots_used", 0))
	var slots_capacity := int(presentation.get("slots_capacity", 0))
	var spirits_used := int(presentation.get("spirits_used", 0))
	var spirits_capacity := int(presentation.get("spirits_capacity", 0))
	var cost_text := String(presentation.get("offer_cost_text", ""))
	var points_subtitle := ("抽取一次消耗 %s" % cost_text) if not cost_text.is_empty() else ""
	_points_card.set_data("理念点", points_text, points_subtitle,
		UITokens.ACCENT, "", "country.politics")
	_slots_card.set_data("意识形态槽", "%d / %d" % [slots_used, slots_capacity],
		"装备中的国家理念", UITokens.BRASS_HIGHLIGHT, "", "country.affairs")
	_spirits_card.set_data("民族精神槽", "%d / %d" % [spirits_used, spirits_capacity],
		"晋升后不可逆", UITokens.RESOURCE, "", "country.economy")
	_points_card.set_compact(_compact)
	_slots_card.set_compact(_compact)
	_spirits_card.set_compact(_compact)


func _show_empty_state(visible: bool, presentation: Dictionary) -> void:
	if _empty == null:
		return
	_empty.visible = visible
	if not visible:
		return
	_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	_empty_title.text = String(presentation.get("empty_title", "尚未形成国家理念"))
	_empty_detail.text = String(presentation.get("empty_detail",
		"内阁还没有选定一条可推行的道路。"))
	var insights: Array = presentation.get("empty_insights", [])
	if _empty_insights != null:
		_empty_insights.visible = not insights.is_empty()
		if not insights.is_empty():
			_empty_insights.set_items(insights)


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
	for card in [_choice_0, _choice_1, _choice_2]:
		if card == null or not card.visible or not card.has_method("summary_text"):
			continue
		summaries.append(String(card.call("summary_text")))
	return summaries
