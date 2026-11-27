extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func set_cell_highlight_set(host, node) -> void:
	if host._cell_highlight_set == node:
		return
	host._cell_highlight_set = node
	host.clear_cell_highlights()


## Paint the cells a card's effect instances resolved to. Returns how many were
## actually painted, so the caller can tell "nothing to show" from "the map
## refused every index" without re-querying the map. An empty input clears.
## `frame` is false for live drafting (peace cession picks), where yanking the
## camera on every toggle would fight the player.

func highlight_cells(host, cells: PackedInt32Array, frame: bool = true) -> int:
	if host._cell_highlight_set == null:
		return 0
	if cells.is_empty():
		host._cell_highlight_set.clear()
		return 0
	var centers = host._selection_component._cell_centers(host, cells)
	host._cell_highlight_set.set_cells(centers,
		host._runtime_host.hex_size if host._runtime_host != null else 22.0,
		host._runtime_host.map_wrap_period_x() if host._runtime_host != null else 0.0)
	if centers.is_empty():
		return 0
	# Frame the first hit, the way select_cell frames the cell the player picked.
	if frame and host._camera != null and host._ui_manager != null:
		host._camera.ensure_point_visible(centers[0], host._ui_manager.map_safe_area())
	return centers.size()



func clear_cell_highlights(host) -> void:
	if host._cell_highlight_set != null:
		host._cell_highlight_set.clear()


## ── peace window (MilitaryPeaceWindow) ───────────────────────────────────
## The window owns the draft; this side only paints it. Kept as three flat
## methods so the window can feature-detect them (`has_method`) in tests and in
## a session that has no WorldRoot children.

func set_peace_highlight_sets(host, candidate_set, draft_set) -> void:
	host._peace_candidate_set = candidate_set
	host._peace_draft_set = draft_set
	host.clear_peace_highlights()



func highlight_peace_candidates(host, cells: PackedInt32Array) -> void:
	host._selection_component._paint_peace_set(host, host._peace_candidate_set, cells)



func highlight_peace_draft(host, cells: PackedInt32Array) -> void:
	host._selection_component._paint_peace_set(host, host._peace_draft_set, cells)



func clear_peace_highlights(host) -> void:
	if host._peace_candidate_set != null:
		host._peace_candidate_set.clear()
	if host._peace_draft_set != null:
		host._peace_draft_set.clear()



func _paint_peace_set(host, node, cells: PackedInt32Array) -> void:
	if node == null:
		return
	if cells.is_empty():
		node.clear()
		return
	var centers = host._selection_component._cell_centers(host, cells)
	node.set_cells(centers,
		host._runtime_host.hex_size if host._runtime_host != null else 22.0,
		host._runtime_host.map_wrap_period_x() if host._runtime_host != null else 0.0)



func _cell_centers(host, cells: PackedInt32Array) -> PackedVector2Array:
	if host._runtime_host == null or not host._runtime_host.has_method("cell_display_centers"):
		return PackedVector2Array()
	var ref_x: float = host._camera.position.x if host._camera != null else 0.0
	return host._runtime_host.cell_display_centers(cells, ref_x)


## Center the camera on a cell without selecting it (war-situation rows).

func focus_map_cell(host, cell_index: int) -> void:
	if host._runtime_host == null or host._runtime_host.current_map() == null or cell_index < 0:
		return
	var cell = host._runtime_host.current_map().cell_at(cell_index)
	if cell == null:
		return
	if host._camera != null and host._ui_manager != null:
		host._camera.ensure_point_visible(host._selection_component._cell_display_world(host, cell), host._ui_manager.map_safe_area())



func ensure_selected_visible(host) -> void:
	if host._selected_cell == null or host._camera == null or host._ui_manager == null:
		return
	host._camera.ensure_point_visible(host._selection_component._cell_display_world(host, host._selected_cell),
		host._ui_manager.map_safe_area())



func select_cell(host, cell) -> void:
	# The peace window is a map-first editing surface: a click on a cession
	# candidate toggles the draft and must not clear the draft highlight or open
	# the cell panel. Checked before clear_cell_highlights() for exactly that
	# reason.
	if cell != null and host._ui_manager != null \
			and host._ui_manager.has_method("handle_peace_map_cell") \
			and bool(host._ui_manager.call("handle_peace_map_cell", int(cell.index))):
		return
	# A pending army order (移动 / 军事控制) takes the next map click instead of
	# opening the cell panel; the order itself decides what the click means.
	if not host._military_order_mode.is_empty() and cell != null \
			and host.military_arm_order_click(int(cell.index)):
		return
	# 选格是"新的地图焦点"：军务档案关闭，右侧回到地块档案。
	if host._ui_manager != null and host._ui_manager.has_method("close_military_dossier"):
		host._ui_manager.call("close_military_dossier")
	# Picking a hex ends whatever card-level question the player was asking:
	# leaving a card's hit set on screen while a different hex is selected reads
	# as "this hex is one of them" and there is no way to tell otherwise.
	host.clear_cell_highlights()
	if cell == null:
		host.clear_selection()
		return
	host._selected_cell = cell
	var display_world = host._selection_component._cell_display_world(host, cell)
	var wrap_period: float = host._runtime_host.map_wrap_period_x() if host._runtime_host != null else 0.0
	if host._highlight != null:
		host._highlight.set_cell_display(cell, host._runtime_host.hex_size if host._runtime_host != null else 22.0,
			display_world, wrap_period)
	if host._ui_manager != null:
		host._ui_manager.show_cell_panel(cell)
	if host._camera != null and host._ui_manager != null:
		host._camera.ensure_point_visible(display_world, host._ui_manager.map_safe_area())
	host.selection_changed.emit(cell)



func clear_selection(host) -> void:
	host._selected_cell = null
	if host._highlight != null:
		host._highlight.clear()
	if host._ui_manager != null:
		host._ui_manager.hide_cell_panel()
	host.selection_changed.emit(null)



func sync_ui(host) -> void:
	host.ClockPresentation._sync_clock_visual_state(host)
	host.ClockPresentation._sync_time_ui(host)
	host._annual_report_flow.try_present()
	host._narrative_flow.try_present()


func sync_time_ui(host) -> void:
	var clock = host._world_clock
	if host._ui_manager == null or clock == null:
		return
	var day := int(clock.day_index())
	if host._runtime_host is WorldRuntimeHost:
		var ui_day: int = host._runtime_host.ui_worker_day()
		if ui_day >= 0:
			day = ui_day
	var date: Dictionary = clock.calendar_date_for_day(day)
	host._ui_manager.update_time_state(clock.year_index_for_day(day), int(date.month),
		int(date.day_of_month), clock.paused or not host.player_confirmation_reason().is_empty(),
		clock.speed_multiplier)



func refresh_country_binding(host) -> void:
	var generator: Variant = host._runtime_host.generator() if host._runtime_host != null else null
	var next = generator.get_country_facade() if generator != null and \
		generator.has_method("get_country_facade") else null
	if host._country_facade != null and host._country_facade.has_signal("country_committed"):
		var old_callback = Callable(host, "_on_country_committed")
		if host._country_facade.country_committed.is_connected(old_callback):
			host._country_facade.country_committed.disconnect(old_callback)
	if host._economy_facade != null and host._economy_facade.has_signal(
			"construction_command_settled"):
		var old_economy_callback = Callable(host, "_on_construction_command_settled")
		if host._economy_facade.construction_command_settled.is_connected(
				old_economy_callback):
			host._economy_facade.construction_command_settled.disconnect(
				old_economy_callback)
	if host._economy_facade != null and host._economy_facade.has_signal(
			"family_colonization_settled"):
		var old_colonization_callback = Callable(
			host, "_on_family_colonization_settled")
		if host._economy_facade.family_colonization_settled.is_connected(
				old_colonization_callback):
			host._economy_facade.family_colonization_settled.disconnect(
				old_colonization_callback)
	var previous_ideology = host._ideology_facade
	if host._ideology_facade != null and host._ideology_facade.has_signal("command_settled"):
		var old_ideology_callback = Callable(host, "_on_ideology_command_settled")
		if host._ideology_facade.command_settled.is_connected(old_ideology_callback):
			host._ideology_facade.command_settled.disconnect(old_ideology_callback)
	host._country_facade = next
	host._player_country_handle = host._runtime_host._resolve_player_country_handle() \
		if next != null else 0
	host._economy_facade = generator.get_economy_facade() if generator != null \
			and generator.has_method("get_economy_facade") else null
	host._ideology_facade = generator.get_ideology_facade() if generator != null \
			and generator.has_method("get_ideology_facade") else null
	if host._country_facade != null and host._country_facade.has_signal("country_committed"):
		var callback = Callable(host, "_on_country_committed")
		if not host._country_facade.country_committed.is_connected(callback):
			host._country_facade.country_committed.connect(callback)
	if host._economy_facade != null and host._economy_facade.has_signal(
			"construction_command_settled"):
		var economy_callback = Callable(host, "_on_construction_command_settled")
		if not host._economy_facade.construction_command_settled.is_connected(
				economy_callback):
			host._economy_facade.construction_command_settled.connect(economy_callback)
	if host._economy_facade != null and host._economy_facade.has_signal(
			"family_colonization_settled"):
		var colonization_callback = Callable(
			host, "_on_family_colonization_settled")
		if not host._economy_facade.family_colonization_settled.is_connected(
				colonization_callback):
			host._economy_facade.family_colonization_settled.connect(
				colonization_callback)
	if host._ideology_facade != previous_ideology:
		host._shown_ideology_generation = 0
	if host._ideology_facade != null and host._ideology_facade.has_signal("command_settled"):
		var ideology_callback = Callable(host, "_on_ideology_command_settled")
		if not host._ideology_facade.command_settled.is_connected(ideology_callback):
			host._ideology_facade.command_settled.connect(ideology_callback)
	if host._country_facade != null:
		host.AudioPresentation._configure_music_situation(host)
		host._sync_era_reward_offer()
		host.AudioPresentation._sync_era_music(host, true)
	host._sync_family_founding_offer()
	host._progression_component.connect_era_advancement_view(host)
	host._configure_narrative_runtime()



func focus_cell(host, cell: int) -> void:
	if host._runtime_host == null or host._camera == null or host._ui_manager == null or cell < 0:
		return
	var map = host._runtime_host.current_map()
	if map == null:
		return
	var cell_obj = map.cell_at(int(cell))
	if cell_obj == null:
		return
	host._camera.ensure_point_visible(host._selection_component._cell_display_world(host, cell_obj),
		host._ui_manager.map_safe_area())




func _cell_display_world(host, cell) -> Vector2:
	var hex_size: float = host._runtime_host.hex_size if host._runtime_host != null else 22.0
	var canonical := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
	var ref_x: float = host._camera.position.x if host._camera != null else canonical.x
	var wrap_period: float = host._runtime_host.map_wrap_period_x() if host._runtime_host != null else 0.0
	return HexUtils.nearest_display_world(canonical, ref_x, wrap_period)

func _is_text_editing(host) -> bool:
	var viewport: Viewport = host.get_viewport()
	if viewport == null:
		return false
	var focus: Control = viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit

func _is_input_blocked_by_ui(host) -> bool:
	# Direct-dispatch guard only. `_unhandled_input` already survived GUI
	# consumption and must not treat leftover HUD button focus as a map lock.
	var viewport: Viewport = host.get_viewport()
	if viewport == null:
		return false
	var focus: Control = viewport.gui_get_focus_owner()
	return focus is Control

func _is_world_pointer_event(host, event: InputEvent) -> bool:
	return event is InputEventMouseButton \
		or event is InputEventMouseMotion \
		or event is InputEventScreenTouch \
		or event is InputEventScreenDrag \
		or event is InputEventMagnifyGesture \
		or event is InputEventPanGesture

func _release_ordinary_ui_focus(host) -> void:
	var viewport: Viewport = host.get_viewport()
	if viewport == null:
		return
	var focus: Control = viewport.gui_get_focus_owner()
	if focus is Control and not (focus is LineEdit or focus is TextEdit):
		viewport.gui_release_focus()
