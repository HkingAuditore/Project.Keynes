extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _on_era_reward_choice_requested(host, generation: int, choice_index: int) -> void:
	var receipt: Dictionary = host.request_command(host.COMMAND_ERA_REWARD_CHOOSE, {
		"offer_generation": generation,
		"choice_index": choice_index,
	})
	if host._ui_manager != null:
		if bool(receipt.get("ok", false)):
			host._ui_manager.show_era_reward_pending()
		else:
			host._ui_manager.show_era_reward_error(String(receipt.get("message", receipt.get("reason", ""))))


func open_era_reward_offer(host) -> void:
	host._era_reward_dismissed_generation = 0
	_sync_era_reward_offer(host)


func dismiss_era_reward_offer(host) -> void:
	if not era_reward_locked(host) or host._ui_manager == null:
		return
	host._era_reward_dismissed_generation = host._era_reward_generation
	host._ui_manager.close_era_reward_offer()


func _sync_era_reward_offer(host) -> void:
	if host._country_facade == null or host._ui_manager == null:
		return
	var offer: Dictionary = host._country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)):
		return
	host._ui_manager.notify_era_reward_offer(offer)
	var generation := int(offer.get("offer_generation", 0))
	var status := String(offer.get("status", "NONE"))
	var changed: bool = generation != host._era_reward_generation or status != host._era_reward_last_status
	host._era_reward_generation = generation
	host._era_reward_last_status = status
	if changed:
		host.era_reward_offer_changed.emit(offer)
	if not era_reward_locked(host):
		if host._ui_manager.is_era_reward_modal_open():
			host._ui_manager.close_era_reward_offer()
		return
	if host._ui_manager.is_era_ceremony_playing() or generation == host._era_reward_dismissed_generation:
		return
	if changed or not host._ui_manager.is_era_reward_modal_open():
		host._ui_manager.show_era_reward_offer(offer)
	if status == "ERROR":
		host._ui_manager.show_era_reward_error(String(offer.get("error", "未知事务错误")))


func era_reward_locked(host) -> bool:
	return host.player_confirmation_reason() == "era_reward_choice_required"


# ─── Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md) ─────


func get_era_advancement_snapshot(host) -> Dictionary:
	return host._era_advancement.snapshot()



func get_procurement_policy(host) -> Dictionary:
	return host._era_advancement.policy()


## Why a fully stocked purchase is still waiting ("" when not blocked).

func get_era_advancement_blocked_reason(host) -> String:
	return host._era_advancement.blocked_reason()



func prepare_era_session(host, save_service: Node) -> Dictionary:
	var handle: int = host._runtime_host._resolve_player_country_handle()
	if handle == 0:
		return {"ok": true}
	var generator = host._runtime_host.generator()
	var country = generator.get_country_facade()
	var bound: Dictionary = country.bind_era_reward_player_country(handle)
	if not bool(bound.get("ok", false)):
		return {"ok": false, "code": bound.get("reason", "era_reward_player_bind_failed")}
	var regimes: Array = country.political_regime_catalog_view().get("definitions", [])
	var loading: bool = host._runtime_host.is_loading_session()
	var sequence: int = 0 if loading else host._progression_component._allocate_command_sequence(host)
	if not host._era_advancement.bind(country, generator.get_economy_facade(), handle, regimes, sequence):
		return {"ok": false, "code": "era_advancement_bind_failed"}
	var saved: Dictionary = save_service.pending_era_advancement() if loading and save_service != null else {}
	return host._era_advancement.stage_restore(saved)


func connect_era_advancement_view(host) -> void:
	if not host._era_advancement.changed.is_connected(host._on_era_advancement_changed):
		host._era_advancement.changed.connect(host._on_era_advancement_changed)
	if not host._era_advancement.era_advanced.is_connected(host._on_era_advancement_advanced):
		host._era_advancement.era_advanced.connect(host._on_era_advancement_advanced)
	host._progression_component._refresh_era_advancement(host, true)



func _refresh_era_advancement(host, force: bool = false) -> void:
	if host._era_advancement == null or not host._era_advancement.is_bound() or host._world_clock == null:
		return
	host._era_advancement.refresh(host._world_clock.day_index(), force)



func _allocate_command_sequence(host) -> int:
	var sequence = host._command_sequence
	host._command_sequence += 1
	return sequence



func _on_era_advancement_changed(host, snapshot: Dictionary) -> void:
	var digest = snapshot.hash()
	if digest == host._era_advancement_snapshot_hash:
		return
	host._era_advancement_snapshot_hash = digest
	host.era_advancement_changed.emit(snapshot)



func _on_era_advancement_advanced(host, old_index: int, new_index: int,
		buffs: PackedStringArray) -> void:
	host.era_advanced.emit(old_index, new_index, buffs)


func ideology_draw_phase(host) -> String:
	return "presenting" if host.player_confirmation_reason() == "ideology_choice_required" else ""


func ideology_offer_eligibility(host) -> Dictionary:
	if host._ideology_facade == null or host._player_country_handle == 0 \
			or not host._ideology_facade.has_method("preview_offer_eligibility"):
		return {"ok": false, "can_draw": false, "can_reroll": false,
			"reason": "ideology_runtime_unavailable"}
	return host._ideology_facade.preview_offer_eligibility(host._player_country_handle)



func _ideology_player_snapshot(host) -> Dictionary:
	if host._ideology_facade == null or host._player_country_handle == 0 \
			or not host._ideology_facade.has_method("snapshot"):
		return {}
	var snapshot: Dictionary = host._ideology_facade.snapshot(host._player_country_handle)
	return snapshot if bool(snapshot.get("ok", false)) else {}



func _sync_ideology_draw(host) -> void:
	if host.player_confirmation_reason() != "ideology_choice_required":
		return
	var snapshot: Dictionary = _ideology_player_snapshot(host)
	var generation := int(snapshot.get("offer_generation", 0))
	if generation == 0 or generation == host._shown_ideology_generation:
		return
	snapshot["offer_eligibility"] = ideology_offer_eligibility(host)
	host._shown_ideology_generation = generation
	if host._ui_manager != null:
		host._ui_manager.open_country_section("ideology")
	host.ideology_offer_ready.emit(snapshot)


func dismiss_ideology_offer(host, generation: int) -> Dictionary:
	return host._runtime_host.submit_player_confirmation("dismiss_ideology", generation)


func family_founding_locked(host) -> bool:
	return host.player_confirmation_reason() == "family_founding_choice_required"


func _on_family_founding_choice_requested(host, offer_id: int, generation: int,
		choice_index: int) -> void:
	var result: Dictionary = host.request_command(host.COMMAND_FAMILY_FOUNDING_CHOOSE, {
		"offer_id": offer_id,
		"generation": generation,
		"choice_index": choice_index,
	})
	if not bool(result.get("ok", false)) and host._ui_manager != null:
		host._ui_manager.show_family_founding_error(String(result.get("message", result.get("reason", ""))))


func _sync_family_founding_offer(host) -> void:
	if host._ui_manager == null:
		return
	if not family_founding_locked(host):
		if host._family_founding_offer_id != 0:
			host._family_founding_offer_id = 0
			host._ui_manager.close_family_founding_offer()
			host.family_founding_offer_changed.emit({})
		return
	var current: Dictionary = host._runtime_host.player_confirmation_view().get("family_offer", {}).duplicate(true)
	var offer_id := int(current.get("offer_id", 0))
	if offer_id == 0 or offer_id == host._family_founding_offer_id:
		return
	host._family_founding_offer_id = offer_id
	host._economy_facade.decorate_family_founding_offer(current)
	host.focus_family_founding_cell(int(current.get("cell", -1)))
	host._ui_manager.show_family_founding_offer(current)
	host.family_founding_offer_changed.emit(current)


func focus_family_founding_cell(host, cell_idx: int = -1) -> void:
	var map = host._runtime_host.current_map() \
		if host._runtime_host != null and host._runtime_host.has_method("current_map") else null
	var resolved_idx = cell_idx
	if resolved_idx < 0 and host._selected_cell != null:
		resolved_idx = int(host._selected_cell.index)
	if map == null or resolved_idx < 0 or resolved_idx >= map.cell_count():
		return
	var target_cell = map.cell_at(resolved_idx)
	if target_cell == null:
		return
	host.select_cell(target_cell)
	if host._highlight is CanvasItem:
		UIAnimation.pulse(host._highlight as CanvasItem, UITokens.ANIM_SLOW)




func capture_view_state(host) -> Dictionary:
	return {
		"selected_cell": int(host._selected_cell.index) if host._selected_cell != null else -1,
		"camera_position": host._camera.global_position if host._camera != null else Vector2.ZERO,
		"camera_zoom": host._camera.zoom if host._camera != null else Vector2.ONE,
		"next_command_sequence": host._command_sequence,
		"annual_report_view": host._annual_report_flow.capture(),
		"era_advancement": host._era_advancement.capture(),
		"narrative_event_view": host._narrative_flow.capture(),
		"narrative_notices": host._narrative_service.capture_notice_history(),
	}

func restore_view_state(host, map, state: Dictionary) -> void:
	host._annual_report_flow.restore(state.get("annual_report_view", {}))
	host._narrative_flow.restore(state.get("narrative_event_view", {}))
	host._narrative_service.restore_notice_history(state.get("narrative_notices", []))
	host._command_sequence = maxi(1, int(state.get("next_command_sequence", 1)))
	if host._camera != null:
		var saved_position = state.get(
			"camera_position", host._camera.global_position)
		if not (saved_position is Vector2):
			saved_position = host._camera.global_position
		var saved_zoom = state.get("camera_zoom", host._camera.zoom)
		if host._camera.has_method("restore_view_state"):
			host._camera.restore_view_state(saved_position, saved_zoom)
		else:
			# Compatibility for minimal camera stubs used by focused tests.
			host._camera.global_position = saved_position
			host._camera.zoom = saved_zoom
	if map != null:
		var selected := int(state.get("selected_cell", -1))
		if selected >= 0 and selected < map.cell_count():
			host.select_cell(map.cell_at(selected))
		else:
			host.clear_selection()
	host._sync_era_reward_offer()
	host._sync_family_founding_offer()
	host._progression_component._sync_ideology_draw(host)
	host.AudioPresentation._sync_era_music(host, true)
	host._annual_report_flow.try_present()
	host._narrative_flow.try_present()

func _resolve_player_country(host) -> Dictionary:
	if host._runtime_host == null or host._world_clock == null:
		return host._result(false, "runtime_unavailable", "游戏尚未就绪，请稍后再试。")
	if host._country_facade == null or host._player_country_handle == 0:
		return host._result(false, "session_unavailable", "当前会话没有玩家国家。")
	return {"ok": true, "code": "ok", "message": "", "facade": host._country_facade}

func _request_research_queue(host, facade, operation: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var technology_id := StringName(args.get("technology_id", &""))
	if technology_id.is_empty():
		return host._result(false, "invalid_args", "缺少科技标识。")
	match operation:
		"enqueue":
			var domain := int(args.get("domain", -1))
			if domain < 0 or domain >= 4:
				return host._result(false, "invalid_args", "科技领域无效。")
			return facade.enqueue_research(host._player_country_handle, technology_id, domain, -1,
				effective_day, sequence)
		"remove":
			return facade.remove_research(host._player_country_handle, technology_id,
				effective_day, sequence)
		"move":
			var move_domain := int(args.get("domain", -1))
			var position := int(args.get("position", -1))
			if move_domain < 0 or move_domain >= 4 or position < 0:
				return host._result(false, "invalid_args", "研究队列位置无效。")
			return facade.move_research(host._player_country_handle, technology_id, move_domain,
				position, effective_day, sequence)
	return host._result(false, "unsupported_command", "未知研究队列操作。")

func _validate_command_args(host, id: StringName, args: Dictionary, facade = null) -> Dictionary:
	return host.PlayerCommandValidation._validate_command_args(
		host._economy_facade,
		host._ideology_facade,
		host.is_milestone_technology,
		id,
		args,
		facade)

func _next_effective_day(host) -> int:
	if host._runtime_host != null and host._runtime_host._native_environment_active:
		return maxi(0, host._runtime_host._runtime_commit_day + 1)
	return maxi(0, host._world_clock.day_index() + 1) if host._world_clock != null else 0


# ─── Military (design §14.3 / contract §2) ──────────────────────────────────

## 玩家军事命令 → 军事 facade 的 op 字符串。见 docs/plans/military-implementation-contract.md §2。
## 只登记面板真正会用到的子集；契约里其余 op（army.transfer/merge/split/rename 等）
## 属于地图交互或后续版本，未登记前一律 unsupported_command，不伪造成功。
