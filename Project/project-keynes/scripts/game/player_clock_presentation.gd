extends RefCounted

## Reflects clock, weather, and time controls in the player session.


static func _on_day_changed(owner: PlayerController, day_idx: int) -> void:
	if owner._runtime_host == null or owner._world_clock == null:
		return
	if owner._world_clock._publishing_runtime_date:
		return
	# Events are read from a completed day. The active worker signals that boundary separately.
	owner._sync_era_reward_offer()
	owner._sync_family_founding_offer()
	owner._progression_component._sync_ideology_draw(owner)
	owner.AudioPresentation._sync_era_music(owner)
	owner.AudioPresentation._sync_event_audio(owner)
	var worker_days: bool = owner._runtime_host.uses_worker_day_commits()
	if not worker_days:
		if owner._music_situation != null:
			owner._music_situation.refresh_global_from_commit()
	if owner._economy_facade != null and owner._player_country_handle != 0 and \
			owner._economy_facade.has_method("dispatch_family_colonization_receipts"):
		owner._economy_facade.dispatch_family_colonization_receipts(
			owner._player_country_handle)
	var ui_started_usec := Time.get_ticks_usec()
	var ui_breakdown: Dictionary = {}
	if owner._ui_manager != null and not worker_days:
		ui_breakdown = owner._ui_manager.refresh_selected_daily_lines(false, day_idx)
		if owner._ui_manager.has_method("notify_committed_day"):
			owner._ui_manager.notify_committed_day()
		# Country workspaces are event-driven. Daily ticks only patch the selected
		# cell and clock; country/economy/ideology commits invalidate their section.
		ui_breakdown["country_summary_ms"] = 0.0
		if owner._ui_manager.has_method("consume_country_ui_perf_summary"):
			var country_ui_perf: Dictionary = owner._ui_manager.consume_country_ui_perf_summary()
			for key in country_ui_perf:
				ui_breakdown[key] = country_ui_perf[key]
			if not country_ui_perf.is_empty():
				ui_breakdown["country_summary_ms"] = float(
					country_ui_perf.get("country_ui_snapshot_ms", 0.0))
		owner.sync_ui()
	owner._runtime_host.finish_daily_tick((Time.get_ticks_usec() - ui_started_usec) / 1000.0, ui_breakdown)



static func _on_season_changed(owner: PlayerController, season_idx: int) -> void:
	if owner._runtime_host != null:
		owner._runtime_host.on_season_changed(season_idx)
	# Runtime dates refresh the selected cell when the matching map is drawn.
	if owner._world_clock != null and owner._world_clock._publishing_runtime_date:
		return
	if owner._ui_manager != null:
		owner._ui_manager.refresh_selected_daily_lines(true)
	owner.sync_ui()



static func _on_year_changed(owner: PlayerController, year_idx: int) -> void:
	if owner._runtime_host != null:
		owner._runtime_host.on_year_changed(year_idx)
	# Runtime dates refresh the selected cell when the matching map is drawn.
	if owner._world_clock != null and owner._world_clock._publishing_runtime_date:
		return
	if owner._ui_manager != null:
		owner._ui_manager.refresh_selected_daily_lines(true)
	owner.sync_ui()



static func _on_visual_day_phase_changed(owner: PlayerController, phase: float) -> void:
	if owner._runtime_host != null:
		owner._runtime_host.on_visual_day_phase_changed(phase)



static func _on_speed_changed(owner: PlayerController, speed: float) -> void:
	if owner._runtime_host != null:
		owner._runtime_host.on_speed_changed(speed)
	owner.ClockPresentation._sync_time_ui(owner)



static func _on_pause_toggled(owner: PlayerController, paused: bool) -> void:
	if owner._world_clock == null:
		return
	if owner._runtime_host != null and owner._runtime_host.has_method("is_runtime_fault_paused") \
			and owner._runtime_host.is_runtime_fault_paused() and not paused:
		owner.sync_ui()
		return
	owner._world_clock.pause(paused)
	owner.sync_ui()



static func _on_speed_selected(owner: PlayerController, speed: float) -> void:
	if owner._world_clock == null:
		return
	if owner._runtime_host != null and owner._runtime_host.has_method("is_runtime_fault_paused") \
			and owner._runtime_host.is_runtime_fault_paused():
		owner.sync_ui()
		return
	owner._world_clock.set_speed(clampf(speed, 1.0, 10.0))
	owner._world_clock.pause(false)
	owner.sync_ui()



static func _on_pause_menu_visibility_changed(owner: PlayerController, open: bool) -> void:
	if owner._world_clock == null:
		return
	if open:
		owner._pause_before_menu = owner._world_clock.paused
		owner._world_clock.pause(true)
	else:
		if owner._runtime_host != null and owner._runtime_host.has_method("is_runtime_fault_paused") \
				and owner._runtime_host.is_runtime_fault_paused():
			owner._world_clock.pause(true)
		else:
			owner._world_clock.pause(owner._pause_before_menu)
	owner.sync_ui()



static func _sync_clock_visual_state(owner: PlayerController) -> void:
	if owner._runtime_host != null and owner._world_clock != null:
		owner._runtime_host.on_clock_running_changed(not owner._world_clock.paused)



static func _sync_time_ui(owner: PlayerController) -> void:
	owner._selection_component.sync_time_ui(owner)
