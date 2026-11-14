extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _on_era_reward_choice_requested(host, generation: int, choice_index: int) -> void:
	host.request_command(host.COMMAND_ERA_REWARD_CHOOSE, {
		"offer_generation": generation,
		"choice_index": choice_index,
	})
	host._sync_era_reward_offer()
	host._drain_era_reward_until_settled()






func open_era_reward_offer(host) -> void:
	# 点击纸徽才进入暂停选择；待领奖励本身不锁住会话。
	if host._popups_suppressed or host._country_facade == null or host._ui_manager == null or host._family_founding_locked \
			or host.ideology_draw_locked() or host._annual_report_flow.is_open():
		return
	var offer: Dictionary = host._country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)) or String(offer.get("status", "NONE")) not in ["OPEN", "ERROR"]:
		return
	if not host._era_reward_locked:
		host._era_reward_resume_running = host._world_clock != null and not host._world_clock.paused
		host._era_reward_previous_speed = host._world_clock.speed_multiplier if host._world_clock != null else 1.0
		host._era_reward_locked = true
	if host._world_clock != null:
		host._world_clock.pause(true)
	host._ui_manager.show_era_reward_offer(offer)
	host._sync_era_reward_offer()
	host.sync_ui()



func dismiss_era_reward_offer(host) -> void:
	# 已提交的跨领域事务必须完成 ACK；尚未选择时可以稍后领取。
	if not host._era_reward_locked or host._era_reward_last_status == "SELECTED_PENDING":
		return
	if host._ui_manager != null:
		host._ui_manager.close_era_reward_offer()
	host._era_reward_locked = false
	if host._world_clock != null:
		host._world_clock.set_speed(host._era_reward_previous_speed)
		host._world_clock.pause(not host._era_reward_resume_running)
	host.sync_ui()



func _sync_era_reward_offer(host) -> void:
	if host._country_facade == null or not host._country_facade.has_method("era_reward_offer"):
		return
	var offer: Dictionary = host._country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)):
		return
	var status = String(offer.get("status", "NONE"))
	host._era_reward_last_status = status
	if host._popups_suppressed:
		if host._era_reward_locked:
			host._era_reward_locked = false
			if host._world_clock != null:
				host._world_clock.set_speed(host._era_reward_previous_speed)
				host._world_clock.pause(not host._era_reward_resume_running)
			if host._ui_manager != null and host._ui_manager.has_method("close_era_reward_offer"):
				host._ui_manager.close_era_reward_offer()
		return
	if host._ui_manager != null:
		host._ui_manager.notify_era_reward_offer(offer)
	if status in ["OPEN", "ERROR"] and not host._era_reward_locked:
		host._era_reward_generation = int(offer.get("offer_generation", 0))
		host.era_reward_offer_changed.emit(offer)
		# 晋升一成，三选一直接推到玩家面前，不要让人再去找按钮点一次。
		# 大典还在播时先让位，下一轮同步会重试。
		var ceremony: bool = host._ui_manager != null and host._ui_manager.has_method("is_era_ceremony_playing") \
			and host._ui_manager.is_era_ceremony_playing()
		if not ceremony:
			host.open_era_reward_offer()
		return
	if status == "OPEN" or status == "SELECTED_PENDING" or status == "ERROR":
		if not host._era_reward_locked:
			host._era_reward_resume_running = host._world_clock != null and not host._world_clock.paused
			host._era_reward_previous_speed = host._world_clock.speed_multiplier \
				if host._world_clock != null else 1.0
			host._era_reward_locked = true
		if host._world_clock != null:
			# Worker-owned Modifier commits only land on a simulated day; run
			# one-day steps until ACK while every other command stays locked.
			if status == "SELECTED_PENDING" and bool(offer.get("settles_on_day_advance", false)):
				host._world_clock.set_speed(1.0)
				host._world_clock.pause(false)
			else:
				host._world_clock.pause(true)
		var changed = host._era_reward_generation != int(offer.get("offer_generation", 0))
		host._era_reward_generation = int(offer.get("offer_generation", 0))
		if host._ui_manager != null:
			if changed or not host._ui_manager.is_era_reward_modal_open():
				host._ui_manager.show_era_reward_offer(offer)
			if status == "SELECTED_PENDING":
				host._ui_manager.show_era_reward_pending()
			elif status == "ERROR":
				host._ui_manager.show_era_reward_error(String(offer.get(
					"error", "未知事务错误")))
		host.era_reward_offer_changed.emit(offer)
		if status == "SELECTED_PENDING":
			host._drain_era_reward_until_settled()
		return
	# NONE also releases a stale lock, e.g. restored player_view without an Offer.
	if host._era_reward_locked:
		if host._ui_manager != null:
			host._ui_manager.close_era_reward_offer()
		if host._world_clock != null:
			host._world_clock.set_speed(host._era_reward_previous_speed)
			host._world_clock.pause(not host._era_reward_resume_running)
		host._era_reward_locked = false
		host._era_reward_generation = 0
		host.sync_ui()
		host.era_reward_offer_changed.emit(offer)
		host._sync_family_founding_offer()



func era_reward_locked(host) -> bool:
	return host._era_reward_locked


# ─── Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md) ─────


func get_era_advancement_snapshot(host) -> Dictionary:
	host._bind_era_advancement()
	return host._era_advancement.snapshot()



func get_procurement_policy(host) -> Dictionary:
	return host._era_advancement.policy()


## Why a fully stocked purchase is still waiting ("" when not blocked).

func get_era_advancement_blocked_reason(host) -> String:
	return host._era_advancement.blocked_reason()



func _era_advancement_preview(host) -> Dictionary:
	# Read-only: validation must not submit anything or consume sequences.
	host._bind_era_advancement()
	return host._era_advancement.preview()



func _bind_era_advancement(host) -> void:
	if host._era_advancement == null:
		return
	if not host._era_advancement.changed.is_connected(host._on_era_advancement_changed):
		host._era_advancement.changed.connect(host._on_era_advancement_changed)
	if not host._era_advancement.era_advanced.is_connected(host._on_era_advancement_advanced):
		host._era_advancement.era_advanced.connect(host._on_era_advancement_advanced)
	if host._country_facade == null or host._player_country_handle == 0:
		return
	var newly_bound: bool = host._era_advancement.bind(host._country_facade, host._economy_facade,
		host._player_country_handle, Callable(host, "_allocate_command_sequence"))
	if newly_bound:
		# Policy and era target are transient on the native side.
		host._era_advancement.push_runtime_state(host._next_effective_day())
		host._refresh_era_advancement(true)



func _restore_era_advancement(host, state) -> void:
	host._bind_era_advancement()
	host._era_advancement.restore(state if state is Dictionary else {})
	if host._era_advancement.is_bound():
		host._era_advancement.push_runtime_state(host._next_effective_day())
	host._refresh_era_advancement(true)



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


## True while a submitted draw/choose/reroll waits for its one-day settlement.
## The "presenting" phase (offer visible, clock paused) is not a lock: the
## player may close the offer and choose later.

func ideology_draw_locked(host) -> bool:
	return host._ideology_draw_phase == "offer" or host._ideology_draw_phase == "choose" \
		or host._ideology_draw_phase == "reroll"



func ideology_draw_phase(host) -> String:
	return host._ideology_draw_phase



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



func _begin_ideology_draw(host, phase: String, sequence: int) -> void:
	if not host._ideology_draw_clock_saved:
		host._ideology_draw_resume_running = host._world_clock != null and not host._world_clock.paused
		host._ideology_draw_previous_speed = host._world_clock.speed_multiplier \
			if host._world_clock != null else 1.0
		host._ideology_draw_clock_saved = true
	var snapshot = host._ideology_player_snapshot()
	host._ideology_draw_baseline_generation = int(snapshot.get("offer_generation", 0))
	host._ideology_draw_start_day = host._world_clock.day_index() if host._world_clock != null else 0
	host._ideology_draw_sequence = sequence
	host._ideology_draw_phase = phase
	# Commands are effective tomorrow: step the world at 1x until the native
	# authority publishes the settled offer (or the timeout fires).
	if host._world_clock != null and not host._era_reward_locked:
		host._world_clock.set_speed(1.0)
		host._world_clock.pause(false)
	host.ideology_draw_state_changed.emit(phase, {"sequence": sequence})
	host.sync_ui()



func _sync_ideology_draw(host) -> void:
	if host._ideology_draw_phase.is_empty():
		return
	if host._popups_suppressed:
		host._finish_ideology_draw("popup_suppressed")
		return
	var snapshot = host._ideology_player_snapshot()
	if host._ideology_draw_phase == "presenting":
		# Offer resolved elsewhere (load, debug grant): release the saved clock.
		if not snapshot.is_empty() and not bool(snapshot.get("offer_active", false)):
			host._finish_ideology_draw("")
		return
	if snapshot.is_empty():
		return
	var active = bool(snapshot.get("offer_active", false))
	var generation = int(snapshot.get("offer_generation", 0))
	if host._ideology_draw_phase == "offer" or host._ideology_draw_phase == "reroll":
		if active and generation > host._ideology_draw_baseline_generation:
			host._ideology_draw_phase = "presenting"
			if host._world_clock != null and not host._era_reward_locked:
				host._world_clock.pause(true)
			host.sync_ui()
			host.ideology_draw_state_changed.emit("presenting", {"offer_generation": generation})
			host.ideology_offer_ready.emit(snapshot)
			return
	elif host._ideology_draw_phase == "choose":
		if not active or generation != host._ideology_draw_baseline_generation:
			host._finish_ideology_draw("")
			return
	var today: int = host._world_clock.day_index() if host._world_clock != null else 0
	if today - host._ideology_draw_start_day > host.IDEOLOGY_DRAW_TIMEOUT_DAYS:
		host._finish_ideology_draw("ideology_draw_timeout")



func _finish_ideology_draw(host, failure_reason: String) -> void:
	var phase = host._ideology_draw_phase
	host._ideology_draw_phase = ""
	host._ideology_draw_sequence = -1
	if host._ideology_draw_clock_saved and host._world_clock != null:
		if host._era_reward_locked:
			# The era-reward lock owns the clock now; hand over the saved state.
			host._era_reward_resume_running = host._ideology_draw_resume_running
			host._era_reward_previous_speed = host._ideology_draw_previous_speed
		else:
			host._world_clock.set_speed(host._ideology_draw_previous_speed)
			host._world_clock.pause(not host._ideology_draw_resume_running)
	host._ideology_draw_clock_saved = false
	host.sync_ui()
	host.ideology_draw_state_changed.emit("", {"previous_phase": phase,
		"reason": failure_reason,
		"message": host._ideology_draw_failure_message(failure_reason)})



func dismiss_ideology_offer(host) -> void:
	if host._ideology_draw_phase == "presenting":
		host._finish_ideology_draw("")



func family_founding_locked(host) -> bool:
	return host._family_founding_locked



func _on_family_founding_choice_requested(host, offer_id: int, generation: int,
		choice_index: int) -> void:
	var result = host.request_command(host.COMMAND_FAMILY_FOUNDING_CHOOSE, {
		"offer_id": offer_id,
		"generation": generation,
		"choice_index": choice_index,
	})
	if not bool(result.get("ok", false)) and host._ui_manager != null \
			and host._ui_manager.has_method("show_family_founding_error"):
		host._ui_manager.show_family_founding_error(String(result.get("message", "")))
	host._sync_family_founding_offer()


## Player-owned milestone offers block the session one at a time. Era rewards
## take precedence: a founding pick waits (hidden) while an era reward is open.

func _sync_family_founding_offer(host) -> void:
	if host._economy_facade == null or not host._economy_facade.has_method(
			"family_founding_offers"):
		return
	var snapshot: Dictionary = host._economy_facade.family_founding_offers(0, 64)
	if not bool(snapshot.get("ok", false)):
		return
	if host._popups_suppressed:
		if host._family_founding_locked:
			host._family_founding_locked = false
			if host._world_clock != null:
				host._world_clock.set_speed(host._family_founding_previous_speed)
				host._world_clock.pause(not host._family_founding_resume_running)
			if host._ui_manager != null and host._ui_manager.has_method("close_family_founding_offer"):
				host._ui_manager.close_family_founding_offer()
		return
	var open_offers: Array = []
	for offer in snapshot.get("offers", []):
		if bool(offer.get("player_choice", false)) \
				and String(offer.get("status", "")) == "OPEN":
			open_offers.append(offer)
	if open_offers.is_empty():
		if host._family_founding_locked:
			if host._ui_manager != null and host._ui_manager.has_method(
					"close_family_founding_offer"):
				host._ui_manager.close_family_founding_offer()
			host._family_founding_locked = false
			host._family_founding_offer_id = 0
			host._family_founding_generation = 0
			if host._era_reward_locked:
				host._era_reward_resume_running = host._family_founding_resume_running
				host._era_reward_previous_speed = host._family_founding_previous_speed
			elif host._world_clock != null:
				host._world_clock.set_speed(host._family_founding_previous_speed)
				host._world_clock.pause(not host._family_founding_resume_running)
			host.sync_ui()
			host.family_founding_offer_changed.emit({})
		return
	if not host._family_founding_locked:
		if host._era_reward_locked:
			host._family_founding_resume_running = host._era_reward_resume_running
			host._family_founding_previous_speed = host._era_reward_previous_speed
		else:
			host._family_founding_resume_running = host._world_clock != null and not host._world_clock.paused
			host._family_founding_previous_speed = host._world_clock.speed_multiplier \
				if host._world_clock != null else 1.0
		host._family_founding_locked = true
	# The era-reward lock owns the clock while held, including its day-advance
	# settlement; the founding pause takes over once that lock releases.
	if host._world_clock != null and not host._era_reward_locked:
		host._world_clock.pause(true)
	var current: Dictionary = open_offers[0]
	current["queue_remaining"] = open_offers.size() - 1
	var changed = int(current.get("offer_id", 0)) != host._family_founding_offer_id
	host._family_founding_offer_id = int(current.get("offer_id", 0))
	host._family_founding_generation = int(current.get("generation", 0))
	if host._ui_manager != null and host._ui_manager.has_method("show_family_founding_offer"):
		if host._era_reward_locked:
			if host._ui_manager.is_family_founding_modal_open():
				host._ui_manager.close_family_founding_offer()
		elif changed or not host._ui_manager.is_family_founding_modal_open():
			host.focus_family_founding_cell(int(current.get("cell", -1)))
			host._ui_manager.show_family_founding_offer(current)
	host.sync_ui()
	if changed:
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
		"era_reward_locked": host._era_reward_locked,
		"era_reward_resume_running": host._era_reward_resume_running,
		"era_reward_previous_speed": host._era_reward_previous_speed,
		"era_reward_generation": host._era_reward_generation,
		"family_founding_locked": host._family_founding_locked,
		"family_founding_resume_running": host._family_founding_resume_running,
		"family_founding_previous_speed": host._family_founding_previous_speed,
		"ideology_draw_phase": host._ideology_draw_phase,
		"ideology_draw_clock_saved": host._ideology_draw_clock_saved,
		"ideology_draw_resume_running": host._ideology_draw_resume_running,
		"ideology_draw_previous_speed": host._ideology_draw_previous_speed,
		"ideology_draw_baseline_generation": host._ideology_draw_baseline_generation,
		"ideology_draw_start_day": host._ideology_draw_start_day,
		"ideology_draw_sequence": host._ideology_draw_sequence,
		"era_advancement": host._era_advancement.to_save(),
		"military_budget": host._military_budget_state.duplicate(),
		"narrative_event_view": host._narrative_flow.capture(),
	}

func restore_view_state(host, map, state: Dictionary) -> void:
	host._annual_report_flow.restore(state.get("annual_report_view", {}))
	host._narrative_flow.restore(state.get("narrative_event_view", {}))
	host._command_sequence = maxi(1, int(state.get("next_command_sequence", 1)))
	host._era_reward_resume_running = bool(state.get("era_reward_resume_running", false))
	host._era_reward_previous_speed = float(state.get("era_reward_previous_speed", 1.0))
	host._era_reward_generation = int(state.get("era_reward_generation", 0))
	host._era_reward_locked = bool(state.get("era_reward_locked", false))
	# 读档恢复待领取提醒；已提交事务仍继续排空，未选择的旧弹窗不强制重开。
	if host._era_reward_locked and host._country_facade != null:
		var restored_offer: Dictionary = host._country_facade.era_reward_offer()
		if bool(restored_offer.get("ok", false)) and String(restored_offer.get("status", "NONE")) in ["OPEN", "ERROR"]:
			host._era_reward_locked = false
			if host._ui_manager != null:
				host._ui_manager.close_era_reward_offer()
			if host._world_clock != null:
				host._world_clock.set_speed(host._era_reward_previous_speed)
				host._world_clock.pause(not host._era_reward_resume_running)
	host._family_founding_resume_running = bool(state.get(
		"family_founding_resume_running", false))
	host._family_founding_previous_speed = float(state.get(
		"family_founding_previous_speed", 1.0))
	host._family_founding_locked = bool(state.get("family_founding_locked", false))
	host._family_founding_offer_id = 0
	host._family_founding_generation = 0
	host._ideology_draw_phase = String(state.get("ideology_draw_phase", ""))
	if not ["", "offer", "presenting", "choose", "reroll"].has(host._ideology_draw_phase):
		host._ideology_draw_phase = ""
	host._ideology_draw_clock_saved = bool(state.get("ideology_draw_clock_saved", false))
	host._ideology_draw_resume_running = bool(state.get("ideology_draw_resume_running", false))
	host._ideology_draw_previous_speed = float(state.get("ideology_draw_previous_speed", 1.0))
	host._ideology_draw_baseline_generation = int(state.get(
		"ideology_draw_baseline_generation", 0))
	host._ideology_draw_start_day = int(state.get("ideology_draw_start_day", 0))
	host._ideology_draw_sequence = int(state.get("ideology_draw_sequence", -1))
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
	host._sync_ideology_draw()
	host._sync_era_music(true)
	host._restore_era_advancement(state.get("era_advancement", {}))
	host._restore_military_budget(state.get("military_budget", {}))
	host._annual_report_flow.try_present()
	host._narrative_flow.try_present()

func _resolve_player_country(host) -> Dictionary:
	if host._runtime_host == null or host._world_clock == null:
		return host._result(false, "runtime_unavailable", "游戏尚未就绪，请稍后再试。")
	var generator: Variant = host._runtime_host.generator()
	if generator == null or not generator.has_method("gameplay_start_report") \
			or not generator.has_method("get_country_facade"):
		return host._result(false, "session_unavailable", "当前不是可操作的正式玩家会话。")
	var start: Dictionary = generator.gameplay_start_report()
	var facade = generator.get_country_facade()
	var cell_idx := int(start.get("cell", -1))
	if not bool(start.get("ok", false)) or facade == null or cell_idx < 0:
		return host._result(false, "session_unavailable", "当前会话没有玩家国家。")
	var summary: Dictionary = facade.cell_summary(cell_idx)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return host._result(false, "player_country_unavailable", "玩家国家尚未可用。")
	host._player_country_handle = int(summary.get("country_handle", 0))
	if host._player_country_handle == 0:
		return host._result(false, "player_country_unavailable", "玩家国家句柄无效。")
	var reward_binding: Dictionary = facade.bind_era_reward_player_country(
		host._player_country_handle) if facade.has_method(
			"bind_era_reward_player_country") else {"ok": false,
				"reason": "era_reward_runtime_unavailable"}
	if not bool(reward_binding.get("ok", false)):
		return host._result(false, String(reward_binding.get("reason",
			"era_reward_player_bind_failed")), "玩家时代奖励身份绑定失败。")
	return {"ok": true, "code": "ok", "message": "", "facade": facade}

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
		host._era_reward_generation,
		host._family_founding_offer_id,
		host._family_founding_generation,
		host.is_milestone_technology,
		host._validate_owned_cell,
		host.ideology_offer_eligibility,
		host._era_advancement_preview,
		host._military_facade,
		host._completed_technology_ids,
		host._state_building_gate,
		host._player_owns_military_cell,
		host._player_country_handle,
		id,
		args,
		facade)

func _validate_owned_cell(host, facade, cell: int) -> Dictionary:
	if facade == null or cell < 0:
		return host._result(false, "invalid_cell", "地块无效。")
	var summary: Dictionary = facade.cell_summary(cell)
	if not bool(summary.get("ok", false)):
		return host._result(false, "invalid_cell", "地块无效。")
	if not bool(summary.get("owned", false)) or \
			int(summary.get("country_handle", 0)) != host._player_country_handle:
		return host._result(false, "territory_not_owned", "只能修改玩家领土的地块税率。")
	return host._result(true, "ok", "")

func _next_effective_day(host) -> int:
	return maxi(0, host._world_clock.day_index() + 1) if host._world_clock != null else 0


# ─── Military (design §14.3 / contract §2) ──────────────────────────────────

## 玩家军事命令 → 军事 facade 的 op 字符串。见 docs/plans/military-implementation-contract.md §2。
## 只登记面板真正会用到的子集；契约里其余 op（army.transfer/merge/split/rename 等）
## 属于地图交互或后续版本，未登记前一律 unsupported_command，不伪造成功。
