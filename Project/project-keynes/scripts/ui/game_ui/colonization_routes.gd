extends RefCounted

## Handles family dispatch and colonization windows and command requests.




static func _locate_cell_from_family_founding(host, cell_index: int) -> void:
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._player_controller != null and host._player_controller.has_method(
			"focus_family_founding_cell"):
		host._player_controller.focus_family_founding_cell(cell_index)
	elif host._player_controller != null and host._map != null and cell_index >= 0:
		var cell: HexCell = host._map.cell_at(cell_index)
		if cell != null:
			host._player_controller.select_cell(cell)
	host._layout_family_founding_dialog()


static func _on_founding_collapsed_changed(host, collapsed: bool) -> void:
	host._layout_country_action_bar()
	if not collapsed and host._player_controller != null:
		host._player_controller.ensure_selected_visible()


static func _cancel_colonization_targeting(host) -> void:
	host._colonization_targeting.clear()
	if host._colonization_panel == null:
		return
	if host._colonization_panel.is_source_picking():
		host._colonization_panel.cancel_source_selection()
	else:
		host._colonization_panel.cancel_target_selection()


static func _on_colonization_planning_context(host, context: Dictionary) -> void:
	if host._colonization_route == null:
		return
	if context.is_empty():
		host._colonization_route.clear_planning_context()
		return
	var sources: PackedInt32Array = context.get("sources", PackedInt32Array())
	host._colonization_route.set_planning_context(sources,
		int(context.get("selected_source", -1)),
		int(context.get("target_cell", -1)))


static func _open_colonization_target(host, target_cell: int, family_handle: int = 0,
		source_cell: int = -1) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_target(target_cell, family_handle, source_cell)
	if host._player_controller != null and host._player_controller.has_method("ensure_selected_visible"):
		host._player_controller.ensure_selected_visible()



static func _open_dispatch_progress(host) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_expeditions()



static func _refresh_dispatch_status(host) -> void:
	if host._top_bar == null:
		return
	if host._player_controller == null:
		host._top_bar.set_dispatch_status(0, 0, 0)
		return
	var counts = [0, 0, 0]
	var offset = 0
	while true:
		var page: Dictionary = host._player_controller.get_family_expeditions(offset, 128)
		if not bool(page.get("ok", false)):
			return
		var states: PackedInt32Array = page.get("states", PackedInt32Array())
		for state in states:
			if state == 4:
				counts[0] += 1
			elif state == 3:
				counts[2] += 1
			else:
				counts[1] += 1
		if not bool(page.get("has_more", false)) or states.is_empty():
			break
		offset += states.size()
	host._top_bar.set_dispatch_status(counts[0], counts[1], counts[2])



static func _on_colonization_requested(host, request: Dictionary) -> void:
	host._open_colonization_target(int(request.get("target_cell", -1)))



static func _on_family_colonization_requested(host, family_handle: int,
		source_cell: int) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_source(source_cell, family_handle)
	if host._player_controller != null and host._player_controller.has_method("ensure_selected_visible"):
		host._player_controller.ensure_selected_visible()



static func _suppress_ui_for_dispatch(host) -> void:
	if host._dispatch_ui_suppressed:
		return
	host._dispatch_ui_suppressed = true
	host._dispatch_previous_inspector_visible = host._right_panel != null and host._right_panel.visible
	host._dispatch_previous_toolbar_visible = host._map_overlay_toolbar != null and host._map_overlay_toolbar.visible
	if host._right_panel != null:
		host._right_panel.hide()
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.hide()



static func _on_dispatch_closed(host) -> void:
	host._colonization_targeting.clear()
	if not host._dispatch_ui_suppressed:
		return
	host._dispatch_ui_suppressed = false
	if host._right_panel != null:
		host._right_panel.visible = host._dispatch_previous_inspector_visible
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.visible = host._dispatch_previous_toolbar_visible
	if host._dispatch_previous_inspector_visible and host._player_controller != null \
			and host._player_controller.has_method("selected_cell"):
		var cell = host._player_controller.selected_cell()
		if cell != null:
			host.show_cell_panel(cell)
	# 派遣 / 议和窗口关掉：静置的叙事弹窗在同一拍接上。
	host.notify_workspace_closed()


static func _on_colonization_start_requested(host, args: Dictionary) -> void:
	if host._player_controller == null or host._colonization_panel == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		&"family.colonization.start", args)
	host._colonization_panel.set_command_result(result)
	host._refresh_dispatch_status()
	if bool(result.get("ok", false)) and result.has("expedition_handle"):
		host._on_expedition_selected(int(result.expedition_handle))



static func _on_colonization_cancel_requested(host, expedition_handle: int) -> void:
	if host._player_controller == null or host._colonization_panel == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		&"family.colonization.cancel", {"expedition_handle": expedition_handle})
	host._colonization_panel.set_command_result(result)
	host._refresh_dispatch_status()
	if bool(result.get("ok", false)):
		host._on_expedition_selected(expedition_handle)



static func _on_expedition_selected(host, expedition_handle: int) -> void:
	if host._player_controller == null or host._colonization_route == null:
		return
	var snapshot: Dictionary = host._player_controller.get_family_expedition_snapshot(
		expedition_handle)
	if bool(snapshot.get("ok", false)):
		host._colonization_route.show_expedition(snapshot)
