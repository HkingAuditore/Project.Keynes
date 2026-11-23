extends RefCounted

# ── peace window (MilitaryPeaceWindow) ──────────────────────────────────

## Open the dedicated peace window for one war. The country shell is full-bleed,
## so it has to close first — the whole point of this window is the map behind it.

static func open_military_peace(host, war_id: int) -> void:
	if host._peace_window == null or host._country_view_model == null:
		return
	if int(war_id) <= 0:
		return
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.close_panel()
	host._colonization_targeting.clear()
	host._suppress_ui_for_dispatch()
	# The window is the only consumer here, so one fresh military model is enough.
	host._country_view_model.invalidate_cache(host.COUNTRY_DIRTY_MILITARY)
	host._peace_window.set_player_controller(host._player_controller)
	host._peace_window.open(int(war_id), host._country_view_model.build("military"))
	var focus_cell = host._peace_focus_cell()
	if focus_cell >= 0 and host._player_controller != null \
			and host._player_controller.has_method("focus_map_cell"):
		host._player_controller.call("focus_map_cell", focus_cell)


static func close_military_peace(host) -> void:
	if host._peace_window != null:
		host._peace_window.close_panel()


static func is_peace_window_open(host) -> bool:
	return host._peace_window != null and bool(host._peace_window.is_open())





static func handle_peace_map_cell(host, cell: int) -> bool:
	if not host.is_peace_window_open():
		return false
	return bool(host._peace_window.handle_map_cell(int(cell)))


static func _peace_focus_cell(host) -> int:
	if host._peace_window == null:
		return -1
	var candidates: PackedInt32Array = host._peace_window.candidate_cells()
	return int(candidates[0]) if not candidates.is_empty() else -1


static func _on_peace_window_closed(host) -> void:
	# No clear_selection_requested() here: the window never moved the selection
	# (it eats map clicks), so closing it must hand the inspector back exactly as
	# the player left it.
	host._on_dispatch_closed()


static func _on_peace_submit_requested(host, payload: Dictionary) -> void:
	if host._player_controller == null or host._peace_window == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		host.PlayerControllerScript.COMMAND_MILITARY_PEACE_PROPOSE, {
			"war_id": int(payload.get("war_id", 0)),
			"terms": payload.get("terms", []),
		})
	host._peace_window.set_command_result(result)


static func _on_peace_locate_requested(host, cell: int) -> void:
	if host._player_controller != null and host._player_controller.has_method("focus_map_cell"):
		host._player_controller.call("focus_map_cell", int(cell))


static func _refresh_peace_window(host) -> void:
	if not host.is_peace_window_open() or host._country_view_model == null or host._peace_window == null:
		return
	host._country_view_model.invalidate_cache(host.COUNTRY_DIRTY_MILITARY)
	host._peace_window.refresh_model(host._country_view_model.build("military"))
