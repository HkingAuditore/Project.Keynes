extends RefCounted

## Applies ideology, promotion, and offer commands and displays their receipts.


static func _open_offer(owner: IdeologyWorkspace) -> void:
	var generation := int(owner._snapshot.get("offer_generation", 0))
	if bool(owner._snapshot.get("offer_active", false)) and generation == owner._dismissed_generation:
		owner._dismissed_generation = -1
		owner._render_top()
		owner._rebuild_offer()
		return
	if owner._player_controller == null:
		return
	var blocked: String = owner._presentation_component._blocking_confirmation_reason(owner, false)
	if not blocked.is_empty():
		owner._show_result({"ok": false, "reason": blocked}); return
	var result: Dictionary = owner._player_controller.request_command(IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	if not bool(result.get("ok", false)): owner._show_result(result)



static func _reroll_offer(owner: IdeologyWorkspace) -> void:
	if owner._player_controller == null: return
	var blocked: String = owner._presentation_component._blocking_confirmation_reason(owner, true)
	if not blocked.is_empty():
		owner._show_result({"ok": false, "reason": blocked}); return
	var result: Dictionary = owner._player_controller.request_command(IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_REROLL, {
		"offer_generation": int(owner._snapshot.get("offer_generation", 0)),
	})
	if bool(result.get("ok", false)):
		owner._render_draw_waiting()
	else:
		owner._show_result(result)



static func _dismiss_offer(owner: IdeologyWorkspace) -> void:
	owner._dismissed_generation = int(owner._snapshot.get("offer_generation", 0))
	if owner._player_controller != null and owner._player_controller.has_method("dismiss_ideology_offer"):
		owner._player_controller.dismiss_ideology_offer(owner._dismissed_generation)
	owner._render_top()
	owner._rebuild_offer()
	owner._offer_button.grab_focus()



static func _command(owner: IdeologyWorkspace, kind: String, ideology_id: int) -> void:
	if owner._player_controller == null or ideology_id < 0:
		return
	var command_id := {
		"equip": IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		"unequip": IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		"promote": IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	}.get(kind, &"") as StringName
	var result: Dictionary = owner._player_controller.request_command(
		command_id, {"ideology_id": ideology_id})
	owner._show_result(result)



static func _request_promotion(owner: IdeologyWorkspace, ideology_id: int) -> void:
	if owner._promotion_layer == null or ideology_id < 0:
		return
	owner._pending_promotion_id = ideology_id
	owner._promotion_copy.text = "将「%s」晋升为民族精神？\n现有国策槽位将转为民族精神，此操作不可撤销。" \
		% owner._display_name(owner._metadata.get(ideology_id, {}), ideology_id)
	owner._promotion_layer.visible = true
	owner._promotion_confirm.grab_focus()



static func _confirm_promotion(owner: IdeologyWorkspace) -> void:
	if owner._pending_promotion_id < 0:
		return
	var ideology_id := owner._pending_promotion_id
	owner._pending_promotion_id = -1
	if owner._promotion_layer != null:
		owner._promotion_layer.visible = false
	owner._command("promote", ideology_id)



static func _on_player_command_completed(owner: IdeologyWorkspace, id: StringName, result: Dictionary) -> void:
	if id in [&"ideology.offer", &"ideology.reroll"] and bool(result.get("ok", false)):
		owner._pending_draw_sequence = int(result.get("sequence", -1))
		owner._render_top()
		owner._rebuild_offer()



static func _on_player_command_settled(owner: IdeologyWorkspace, id: StringName, result: Dictionary) -> void:
	if id not in [
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_OFFER,
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE,
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_REROLL,
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	]:
		return
	if owner._pending_draw_sequence == int(result.get("sequence", -2)):
		owner._pending_draw_sequence = -1
		owner._render_top()
		owner._rebuild_offer()
	if bool(result.get("ok", false)):
		owner._flash_hint("")
	else:
		var message := CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。"))))
		owner._flash_hint(message)
		owner._toast(message)



static func _on_ideology_offer_ready(owner: IdeologyWorkspace, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	owner._snapshot = snapshot
	owner._presentation = CountryViewModel.present_ideology(owner._snapshot, owner._catalog)
	owner._index_states()
	if bool(owner._snapshot.get("offer_active", false)) and int(owner._snapshot.get("offer_generation", 0)) > owner._revealed_generation:
		owner._pending_draw_sequence = -1
	owner._dismissed_generation = -1
	owner._hint_hold_until = 0
	owner._render_top()
	owner._rebuild_offer()



static func _show_result(owner: IdeologyWorkspace, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		owner._flash_hint(CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。")))))
		if owner._compact:
			owner._toast(owner._hint.text)
