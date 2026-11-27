extends RefCounted

## Adapts committed simulation notifications for session presentation.


static func _on_simulation_view_updated(owner: PlayerController, _from_day: int, to_day: int, _generation: int) -> void:
	if owner._runtime_host == null or owner._world_clock == null:
		return
	if owner._camera == null or owner._camera.drawn_frame == null:
		owner.refresh_selected_map_view(to_day)



static func refresh_selected_map_view(owner: PlayerController, day: int) -> void:
	if owner._ui_manager != null and owner._selected_cell != null:
		owner._ui_manager.refresh_selected_daily_lines(false, day)
	if owner._ui_manager != null and owner._ui_manager.has_method("notify_committed_day"):
		owner._ui_manager.notify_committed_day()



static func _on_simulation_ui_updated(owner: PlayerController, _from_day: int, _to_day: int, _generation: int) -> void:
	owner.ClockPresentation._sync_time_ui(owner)



static func _on_simulation_day_records(owner: PlayerController, _records: Array) -> void:
	var commit: Dictionary = owner._runtime_host._runtime_last_commit
	owner._narrative_service.apply_notice_history(commit.get("notice_history", []))



static func player_confirmation_reason(owner: PlayerController) -> String:
	if owner._runtime_host == null or not owner._runtime_host.has_method("player_confirmation_view"):
		return ""
	return String(owner._runtime_host.player_confirmation_view().get("reason", ""))



static func _on_player_confirmation_updated(owner: PlayerController, view: Dictionary) -> void:
	var suppress := bool(view.get("suppress_event_popups", false))
	var reason := String(view.get("reason", ""))
	owner._annual_report_flow.set_popups_suppressed(suppress and reason != "annual_report_confirmation_required")
	owner._narrative_flow.set_popups_suppressed(suppress and reason != "narrative_choice_required")
	owner._sync_era_reward_offer()
	owner._sync_family_founding_offer()
	owner._progression_component._sync_ideology_draw(owner)
	owner._annual_report_flow.try_present()
	owner._narrative_flow.try_present()
	owner.ClockPresentation._sync_time_ui(owner)



static func _on_simulation_command_results(owner: PlayerController, results: Array) -> void:
	for result: Dictionary in results:
		var id := StringName(result.get("command", ""))
		if id in [PlayerController.COMMAND_ERA_REWARD_CHOOSE, PlayerController.COMMAND_FAMILY_FOUNDING_CHOOSE]:
			if not bool(result.get("ok", false)):
				var reason := String(result.get("reason", ""))
				result["message"] = PlayerController._confirmation_error_message(reason)
				if owner._ui_manager != null:
					if id == PlayerController.COMMAND_ERA_REWARD_CHOOSE:
						owner._ui_manager.show_era_reward_error(result.message)
					else:
						owner._ui_manager.show_family_founding_error(result.message)
		elif id in [PlayerController.COMMAND_FAMILY_COLONIZATION_START, PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL]:
			if bool(result.get("ok", false)):
				continue
			result["message"] = PlayerController._colonization_command_message(String(result.get("code", "")))
		elif id in [PlayerController.COMMAND_ERA_ADVANCE_START, PlayerController.COMMAND_ERA_ADVANCE_PAUSE,
				PlayerController.COMMAND_ERA_ADVANCE_RESUME, PlayerController.COMMAND_PROCUREMENT_SET_POLICY]:
			owner._progression_component._refresh_era_advancement(owner, true)
		elif not bool(result.get("ok", false)):
			var code := String(result.get("code", "command_rejected"))
			if code == "country_cell_tax_territory_invalid":
				result["message"] = "只能修改本国领土的地块税率。"
			elif String(id).begins_with("military."):
				result["message"] = PlayerController.PlayerControllerMilitaryScript.command_rejection_message(code)
		owner.command_settled.emit(id, result)



static func _on_simulation_committed(owner: PlayerController, _from_day: int, _to_day: int, _generation: int) -> void:
	if owner._runtime_host == null or owner._world_clock == null:
		return
	if owner._music_situation != null:
		owner._music_situation.refresh_global_from_commit()
	owner._sync_era_reward_offer()
	owner._sync_family_founding_offer()
	owner._progression_component._sync_ideology_draw(owner)
	owner.AudioPresentation._sync_era_music(owner)
	owner.AudioPresentation._sync_event_audio(owner)
	owner._progression_component._refresh_era_advancement(owner)
	owner._narrative_service.consume_committed()
	owner._annual_report_flow.try_present()
	owner._narrative_flow.try_present()



static func _on_country_committed(owner: PlayerController, report: Dictionary) -> void:
	owner.country_committed.emit(report)
	owner._sync_era_reward_offer()
	owner._sync_family_founding_offer()
	owner.AudioPresentation._sync_era_music(owner)
	# Country ACK of advance_era raises current_era_index here.
	owner._progression_component._refresh_era_advancement(owner, true)



static func _on_construction_command_settled(owner: PlayerController, result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != owner._player_country_handle:
		return
	owner.command_settled.emit(StringName(result.get("command", PlayerController.COMMAND_CONSTRUCTION_BUILD)), result)



static func _on_family_colonization_settled(owner: PlayerController, result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != owner._player_country_handle:
		return
	var command_id := PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL \
		if String(result.get("code", "")) == "CANCELLED_RETURNING" \
		else PlayerController.COMMAND_FAMILY_COLONIZATION_START
	owner.command_settled.emit(command_id, result)



static func _on_ideology_command_settled(owner: PlayerController, result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != owner._player_country_handle:
		return
	var command_id := {
		3: PlayerController.COMMAND_IDEOLOGY_OFFER,
		4: PlayerController.COMMAND_IDEOLOGY_CHOOSE,
		5: PlayerController.COMMAND_IDEOLOGY_EQUIP,
		6: PlayerController.COMMAND_IDEOLOGY_UNEQUIP,
		7: PlayerController.COMMAND_IDEOLOGY_PROMOTE,
		10: PlayerController.COMMAND_IDEOLOGY_REROLL,
	}.get(int(result.get("opcode", 0)), &"ideology.unknown") as StringName
	owner.command_settled.emit(command_id, result)
