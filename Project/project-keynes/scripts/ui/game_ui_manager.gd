class_name GameUIManager
extends "res://scripts/ui/game_ui/hud_presentation.gd"

## Connects the game HUD scene and player session to the presentation routes.


func _ready() -> void:
	layer = 20
	# [qa-ui-hide 2026-11-02] 二分"渲染线程崩溃是否由 UI 绘制引起"：
	# PK_UI_HIDE_ALL=1（桌面）或 pk_debug.cfg 的 `[ui] hide_all=true`（安卓）时
	# 整层 UI 隐藏（世界照常渲染）。正式包不设这些开关。
	var hide_all := OS.get_environment("PK_UI_HIDE_ALL") == "1"
	if not hide_all:
		var qa_cfg := ConfigFile.new()
		if qa_cfg.load("user://pk_debug.cfg") == OK:
			hide_all = bool(qa_cfg.get_value("ui", "hide_all", false))
	if hide_all:
		visible = false
		print("[ui] QA: HUD hidden")
	_country_ui_event_refresh_enabled = bool(Engine.get_meta(
		&"country_ui_event_refresh_enabled", true))
	_gm_available = gm_available_for_build(OS.is_debug_build(), Engine.is_editor_hint())
	_bind_ui()
	show_loading("正在生成世界")


static func gm_available_for_build(debug_build: bool, editor_hint: bool) -> bool:
	return debug_build or editor_hint


func set_diagnostics_source(source: Node) -> void:
	if _diagnostics_source != null and _diagnostics_source.has_signal("gm_toggle_changed"):
		var old_callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if _diagnostics_source.is_connected("gm_toggle_changed", old_callback):
			_diagnostics_source.disconnect("gm_toggle_changed", old_callback)
	if _diagnostics_source != null and _diagnostics_source.has_signal("gm_tod_preview_changed"):
		var old_sun_callback := Callable(self, "_on_gm_tod_preview_changed")
		if _diagnostics_source.is_connected("gm_tod_preview_changed", old_sun_callback):
			_diagnostics_source.disconnect("gm_tod_preview_changed", old_sun_callback)
	_diagnostics_source = source
	if source != null and source.has_signal("gm_toggle_changed"):
		var callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if not source.is_connected("gm_toggle_changed", callback):
			source.connect("gm_toggle_changed", callback)
	if source != null and source.has_signal("gm_tod_preview_changed"):
		var sun_callback := Callable(self, "_on_gm_tod_preview_changed")
		if not source.is_connected("gm_tod_preview_changed", sun_callback):
			source.connect("gm_tod_preview_changed", sun_callback)
	if _gm_console != null:
		_gm_console.set_main(source)
	if _perf_hud != null:
		_perf_hud.set_main(source)
	_sync_military_map_toolbar()


func set_era_ceremony_suppressed(enabled: bool) -> void:
	_era_ceremony_suppressed = enabled
	if enabled and is_era_ceremony_playing():
		_era_ceremony.skip()


func _ensure_era_panel() -> void:
	if _era_panel != null and is_instance_valid(_era_panel):
		return
	var host := get_node_or_null("UIRoot/EraOverlayLayer") as Control
	if host == null:
		return
	_era_panel = EraAdvancementPanelScene.instantiate() as EraAdvancementPanel
	_era_panel.name = "EraAdvancementPanel"
	host.add_child(_era_panel)
	# 纸笺垫底、晋升光带压在上面。纸徽已归 HUDLayer（面板之下），这里不再需要把它排在纸徽之前。
	host.move_child(_era_panel, 0)
	_bind_era_panel()


func _start_era_ceremony(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	_era_component._start_era_ceremony(self, old_index, new_index, buffs)


func set_player_controller(controller) -> void:
	if _player_controller != null and _player_controller.has_signal("command_completed"):
		var old_audio := Callable(self, "_on_player_command_completed_audio")
		if _player_controller.command_completed.is_connected(old_audio):
			_player_controller.command_completed.disconnect(old_audio)
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var old_callback := Callable(self, "_on_country_committed")
		if _player_controller.country_committed.is_connected(old_callback):
			_player_controller.country_committed.disconnect(old_callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var old_settled := Callable(self, "_on_player_command_settled")
		if _player_controller.command_settled.is_connected(old_settled):
			_player_controller.command_settled.disconnect(old_settled)
	_disconnect_era_advancement_signals()
	_player_controller = controller
	if _pause_menu != null:
		_pause_menu.event_pause_reader = Callable(controller.narrative_service(), "event_pause_mask") \
			if controller != null and controller.has_method("narrative_service") else Callable()
	_connect_era_advancement_signals()
	if _player_controller != null and _player_controller.has_signal("command_completed"):
		var audio_callback := Callable(self, "_on_player_command_completed_audio")
		if not _player_controller.command_completed.is_connected(audio_callback):
			_player_controller.command_completed.connect(audio_callback)
	if _country_panel != null and _country_panel.has_method("set_player_controller"):
		_country_panel.set_player_controller(controller)
	if _right_panel != null and _right_panel.has_method("set_player_controller"):
		_right_panel.set_player_controller(controller)
	if _colonization_panel != null:
		_colonization_panel.set_player_controller(controller)
	_refresh_dispatch_status()
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var callback := Callable(self, "_on_country_committed")
		if not _player_controller.country_committed.is_connected(callback):
			_player_controller.country_committed.connect(callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var settled := Callable(self, "_on_player_command_settled")
		if not _player_controller.command_settled.is_connected(settled):
			_player_controller.command_settled.connect(settled)


func _connect_era_advancement_signals() -> void:
	if _player_controller == null:
		return
	if _player_controller.has_signal("era_advancement_changed"):
		var changed := Callable(self, "_on_era_advancement_changed")
		if not _player_controller.era_advancement_changed.is_connected(changed):
			_player_controller.era_advancement_changed.connect(changed)
	if _player_controller.has_signal("era_advanced"):
		var advanced := Callable(self, "_on_player_era_advanced")
		if not _player_controller.era_advanced.is_connected(advanced):
			_player_controller.era_advanced.connect(advanced)


func _disconnect_era_advancement_signals() -> void:
	if _player_controller == null:
		return
	if _player_controller.has_signal("era_advancement_changed"):
		var changed := Callable(self, "_on_era_advancement_changed")
		if _player_controller.era_advancement_changed.is_connected(changed):
			_player_controller.era_advancement_changed.disconnect(changed)
	if _player_controller.has_signal("era_advanced"):
		var advanced := Callable(self, "_on_player_era_advanced")
		if _player_controller.era_advanced.is_connected(advanced):
			_player_controller.era_advanced.disconnect(advanced)


func _bind_ui() -> void:
	_top_bar = get_node("UIRoot/HUDLayer/PlayerTopBar") as PlayerTopBar
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.day_night_toggled.connect(
		func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_top_bar.setup_requested.connect(toggle_pause_menu)
	_top_bar.gm_requested.connect(toggle_gm_panel)
	_top_bar.annual_history_requested.connect(func() -> void: annual_history_requested.emit())
	_top_bar.dispatch_requested.connect(_open_dispatch_progress)
	_top_bar.set_gm_available(false)
	_layout_top_bar()
	_status_card = get_node_or_null("UIRoot/HUDLayer/HudStatusCard") as HudStatusCard
	if _status_card != null:
		_top_bar.status_hovered.connect(_on_top_bar_status_hovered)
		_top_bar.status_pressed.connect(_on_top_bar_status_pressed)

	_right_panel = get_node("UIRoot/PanelLayer/RightPanel") as InspectorPanel
	_right_panel.set_player_controller(_player_controller)
	_right_panel.close_requested.connect(func() -> void: clear_selection_requested.emit())
	_right_panel.population_discontent_changed.connect(population_discontent_changed.emit)
	_right_panel.tab_data_requested.connect(_on_inspector_tab_data_requested)
	_right_panel.visibility_changed.connect(_on_inspector_visibility_changed)
	_right_panel.object_details_requested.connect(_on_object_details_requested)
	_right_panel.detail_visibility_changed.connect(
		_on_inspector_detail_visibility_changed)
	_right_panel.list_wing_visibility_changed.connect(
		_on_inspector_list_wing_visibility_changed)
	_right_panel.family_colonization_requested.connect(
		_on_family_colonization_requested)
	_right_panel.construction_page_requested.connect(_on_construction_page_requested)
	_right_panel.construction_requested.connect(_on_construction_requested)
	_right_panel.construction_fold_action_requested.connect(
		_on_construction_fold_action_requested)
	_right_panel.colonization_requested.connect(_on_colonization_requested)
	_right_panel.trade_orders_page_requested.connect(
		_on_trade_orders_page_requested)
	_right_panel.trade_order_locate_requested.connect(
		_on_trade_order_locate_requested)
	_right_panel.military_state_building_requested.connect(
		_on_military_state_building_requested)
	_right_panel.military_army_create_requested.connect(
		_on_military_army_create_requested)
	_right_panel.military_army_selected.connect(
		_on_military_army_selected)
	_right_panel.military_dossier_action_requested.connect(
		_on_military_dossier_action_requested)
	_right_panel.military_dossier_army_selected.connect(
		_on_military_dossier_army_selected)
	_layout_right_panel()

	_colonization_panel = get_node(
		"UIRoot/ModalLayer/ColonizationPlannerPanel") as ColonizationPlannerPanel
	_colonization_panel.set_player_controller(_player_controller)
	_colonization_panel.closed.connect(_on_dispatch_closed)
	_colonization_panel.target_selection_requested.connect(func() -> void:
		_colonization_targeting = {"active": true})
	_colonization_panel.source_selection_requested.connect(func() -> void:
		_colonization_targeting = {"active": true})
	_colonization_panel.planning_context_changed.connect(_on_colonization_planning_context)
	_colonization_panel.route_requested.connect(func(detail: Dictionary) -> void:
		if _colonization_route != null:
			_colonization_route.show_quote(detail)
	)
	_colonization_panel.route_cleared.connect(func() -> void:
		if _colonization_route != null:
			_colonization_route.clear_route()
	)
	_colonization_panel.start_requested.connect(_on_colonization_start_requested)
	_colonization_panel.cancel_requested.connect(_on_colonization_cancel_requested)
	_colonization_panel.expedition_selected.connect(_on_expedition_selected)
	_refresh_dispatch_status()
	# 议和窗口：与开拓面板同一条「地图作业面」通道，但它的草案是交割地块。
	_peace_window = get_node_or_null("UIRoot/ModalLayer/MilitaryPeaceWindow")
	if _peace_window != null:
		_peace_window.closed.connect(_on_peace_window_closed)
		_peace_window.submit_requested.connect(_on_peace_submit_requested)
		_peace_window.locate_cell_requested.connect(_on_peace_locate_requested)
	_debug_layer = get_node("UIRoot/DebugLayer") as Control

	if _gm_available:
		_gm_console = DebugConsole.new()
		_gm_console.name = "GMConsole"
		_gm_console.console_mode = DebugConsole.ConsoleMode.PLAYER_GM
		_gm_console.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		_gm_console.custom_minimum_size = Vector2.ZERO
		_debug_layer.add_child(_gm_console)
		_gm_console.set_gm_local_toggle_provider(
			Callable(self, "_get_local_gm_toggle_state"),
			Callable(self, "_set_local_gm_toggle"))
		_gm_console.visibility_changed.connect(_sync_gm_sun_handle)
		_gm_console.visibility_changed.connect(func() -> void:
			if not _gm_console.visible:
				notify_workspace_closed())
		_layout_gm_panel()

	_perf_hud = get_node("UIRoot/HUDLayer/PerfMiniHUD") as PerfMiniHUD

	_map_overlay_toolbar = get_node("UIRoot/HUDLayer/MapOverlayToolbar") as MapOverlayToolbar
	_map_overlay_toolbar.overlay_requested.connect(_on_map_overlay_requested)
	_map_overlay_toolbar.overlay_cleared.connect(_on_map_overlay_cleared)
	_layout_map_overlay_toolbar()
	_military_map_toolbar = get_node_or_null("UIRoot/HUDLayer/MilitaryMapToolbar") as MilitaryMapToolbar
	if _military_map_toolbar != null:
		_military_map_toolbar.layer_toggled.connect(_on_military_layer_toggled)

	_country_action_bar = get_node("UIRoot/HUDLayer/CountryActionBar") as CountryActionBar
	_country_action_bar.section_selected.connect(open_country_section)
	_layout_country_action_bar()
	_ensure_research_toast()

	_map_overlay_legend = get_node("UIRoot/HUDLayer/MapOverlayLegend") as OverlayLegend
	# Bottom-right is outside the map's main reading line and the left tool
	# palette. The layout helper shifts it left whenever Inspector is visible.
	_map_overlay_legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_map_overlay_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_map_overlay_legend.grow_vertical = Control.GROW_DIRECTION_BEGIN
	get_viewport().size_changed.connect(_layout_overlay_legend)
	get_viewport().size_changed.connect(_layout_gm_panel)
	get_viewport().size_changed.connect(_layout_country_action_bar)
	get_viewport().size_changed.connect(_layout_top_bar)
	get_viewport().size_changed.connect(_layout_right_panel)
	get_viewport().size_changed.connect(_layout_family_founding_dialog)
	get_viewport().size_changed.connect(_apply_ui_safe_area)
	get_viewport().size_changed.connect(_apply_touch_hud_metrics)
	_apply_ui_safe_area()
	_apply_touch_hud_metrics()
	_layout_overlay_legend()
	_log_ui_layout_diagnostics("bind_ui")

	if _diagnostics_source != null:
		set_diagnostics_source(_diagnostics_source)

	_country_panel = get_node("UIRoot/PanelLayer/CountryPanel") as CountryPanel
	_country_panel.close_requested.connect(func() -> void:
		if _country_action_bar != null:
			_country_action_bar.set_active("")
		_restore_inspector_after_country()
	)
	_country_panel.section_selected.connect(open_country_section)
	_country_panel.locate_cell_requested.connect(_locate_cell_from_country_panel)
	_country_panel.target_cells_requested.connect(_on_target_cells_from_country_panel)
	if _country_panel.has_signal("peace_negotiation_requested"):
		_country_panel.peace_negotiation_requested.connect(open_military_peace)
	if _country_panel.has_signal("military_dossier_requested"):
		_country_panel.military_dossier_requested.connect(open_military_dossier)

	_loading_overlay = get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as WorldLoadingOverlay

	_annual_report_workspace = AnnualReportWorkspaceScene.instantiate()
	var modal_layer := get_node("UIRoot/ModalLayer") as Control
	modal_layer.add_child(_annual_report_workspace)
	_annual_report_workspace.closed.connect(func(id: int) -> void:
		annual_report_closed.emit(id)
		notify_workspace_closed())
	_annual_report_workspace.report_selected.connect(func(id: int) -> void: annual_report_selected.emit(id))
	_annual_report_workspace.history_page_requested.connect(func(offset: int) -> void: annual_history_page_requested.emit(offset))
	modal_layer.visibility_changed.connect(_announce_annual_report_workspace)
	_annual_report_workspace.tree_entered.connect(_announce_annual_report_workspace)
	_announce_annual_report_workspace()
	_pause_menu = get_node("UIRoot/ModalLayer/PauseMenu") as PauseMenu
	_pause_menu.visibility_requested.connect(
		func(open: bool) -> void: pause_menu_visibility_changed.emit(open))
	_pause_menu.return_menu_requested.connect(func() -> void: return_main_menu_requested.emit())
	_pause_menu.exit_requested.connect(func() -> void: exit_game_requested.emit())
	_era_reward_dialog = get_node(
		"UIRoot/ModalLayer/EraRewardDialog") as EraRewardDialog
	_era_reward_dialog.choice_requested.connect(
		func(generation: int, index: int) -> void:
			era_reward_choice_requested.emit(generation, index))
	_era_reward_dialog.dismiss_requested.connect(_on_era_popup_dismissed)
	# 时代徽记只是 HUD：挂在 HUDLayer 末位，画在日期栏之上、所有面板之下——
	# 国家卷宗的压暗遮罩、右侧检视面板与全部模态窗都能照常盖住它。
	# 晋升光带与纸笺仍在 EraOverlayLayer（PanelLayer 之上、ModalLayer 之下），
	# 让「徽记飞回日历」这类一次性演出在打开的卷宗之上仍然看得见。
	_era_indicator = get_node("UIRoot/HUDLayer/EraIndicator") as EraIndicator
	_era_flight = get_node("UIRoot/EraOverlayLayer/EraTransitionFlight") as Control
	_era_indicator.era_advanced.connect(_on_era_indicator_advanced)
	# defer 只在大典播放期间为真：大典结束后纸徽必须自己跟上模型，
	# 否则一旦接管的 landed 路径没走到，图标会永远停在旧时代。
	_era_indicator.defer_celebration = false
	_era_flight.landed.connect(_on_era_flight_landed)
	_era_indicator.pressed.connect(_on_era_indicator_pressed)
	_ensure_era_panel()
	_family_founding_dialog = get_node_or_null(
		"UIRoot/ModalLayer/FamilyFoundingDialog") as FamilyFoundingDialog
	if _family_founding_dialog != null:
		_family_founding_dialog.choice_requested.connect(
			func(offer_id: int, generation: int, index: int) -> void:
				family_founding_choice_requested.emit(offer_id, generation, index))
		_family_founding_dialog.locate_cell_requested.connect(
			_locate_cell_from_family_founding)
		_family_founding_dialog.inspector_close_requested.connect(func() -> void:
			if _right_panel != null:
				_right_panel.close_detail())
		_family_founding_dialog.collapsed_changed.connect(_on_founding_collapsed_changed)
		_layout_family_founding_dialog()
	_ensure_cell_hover_card()
	_ensure_narrative_ui()


func _unhandled_input(event: InputEvent) -> void:
	# 议和窗口没有独立的「选点模式」——窗口开着时任何左键都算交割，所以 Esc 直接关窗。
	if is_peace_window_open() and event is InputEventKey and event.pressed \
			and not event.echo and event.keycode == KEY_ESCAPE:
		close_military_peace()
		get_viewport().set_input_as_handled()
		return
	if _status_card != null and _status_card.is_open() and TouchUI.is_touch():
		if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed):
			_status_card_generation += 1
			_status_card_kind = ""
			_status_card.hide_card(true)
	if _colonization_panel == null or not (_colonization_panel.is_source_picking() \
			or _colonization_panel.is_target_picking()):
		return
	# 只有 Esc 退出显式选点。右键是地图平移键，吃掉它等于废掉拖动视角。
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_cancel_colonization_targeting()
		get_viewport().set_input_as_handled()


func show_era_reward_offer(offer: Dictionary) -> void:
	_era_component.show_era_reward_offer(self, offer)


func _build_era_overview() -> Dictionary:
	return _era_component._build_era_overview(self)


func _on_era_indicator_pressed() -> void:
	_era_component._on_era_indicator_pressed(self)


func _bind_era_panel() -> void:
	_era_panel.close_requested.connect(_close_era_panel)
	_era_panel.command_requested.connect(_on_era_panel_command)
	_era_panel.treasury_requested.connect(func() -> void:
		_close_era_panel()
		open_country_section("economy", "overview"))
	_era_panel.reward_requested.connect(func() -> void:
		era_reward_open_requested.emit())


func _close_era_panel() -> void:
	_era_component._close_era_panel(self)


func is_era_panel_open() -> bool:
	return _era_component.is_era_panel_open(self)


func _on_era_panel_command(command: StringName) -> void:
	_era_component._on_era_panel_command(self, command)


func _era_advancement_model(fresh: bool = false) -> Dictionary:
	return _era_component._era_advancement_model(self, fresh)


func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	_era_component._on_era_advancement_changed(self, snapshot)


func _apply_era_advancement(snapshot: Dictionary) -> void:
	_era_component._apply_era_advancement(self, snapshot)


func _on_era_popup_dismissed() -> void:
	_era_component._on_era_popup_dismissed(self)


func notify_era_reward_offer(offer: Dictionary) -> void:
	_era_component.notify_era_reward_offer(self, offer)


func _queue_era_indicator_refresh() -> void:
	if _era_refresh_queued or not is_inside_tree():
		return
	_era_refresh_queued = true
	get_tree().create_timer(0.10).timeout.connect(func() -> void:
		_era_refresh_queued = false
		_refresh_era_indicator())


func _refresh_era_indicator() -> void:
	if publication_views != null and publication_views.defer_ui_refresh(_refresh_era_indicator):
		return
	_era_component._refresh_era_indicator(self)


func _refresh_player_country_status(country_facade, economy_facade, handle: int) -> void:
	_era_component._refresh_player_country_status(self, country_facade, economy_facade, handle)


func _on_top_bar_status_hovered(kind: String, entered: bool) -> void:
	if _status_card == null or not is_inside_tree() or _top_bar == null:
		return
	if TouchUI.is_touch():
		return
	_status_card_generation += 1
	var generation := _status_card_generation
	if not entered:
		await get_tree().create_timer(STATUS_CARD_HIDE_DELAY).timeout
		if generation == _status_card_generation and _status_card != null:
			_status_card.hide_card()
			_status_card_kind = ""
		return
	await get_tree().create_timer(STATUS_CARD_SHOW_DELAY).timeout
	if generation != _status_card_generation or _status_card == null:
		return
	var model := _build_status_card_model(kind)
	if model.is_empty():
		return
	_status_card_kind = kind
	_status_card_next_refresh_ms = Time.get_ticks_msec() + STATUS_CARD_REFRESH_MSEC
	_status_card.show_card(model, _top_bar.status_anchor(kind))


func _on_top_bar_status_pressed(kind: String) -> void:
	_era_component._on_top_bar_status_pressed(self, kind)


func _refresh_status_card() -> void:
	_era_component._refresh_status_card(self)


func _build_status_card_model(kind: String) -> Dictionary:
	return _era_component._build_status_card_model(self, kind)


func _on_era_indicator_advanced(model: Dictionary) -> void:
	_era_component._on_era_indicator_advanced(self, model)


func _on_player_era_advanced(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	_era_component._on_player_era_advanced(self, old_index, new_index, buffs)


func _ceremony_buffs_from_snapshot(new_index: int) -> PackedStringArray:
	return _era_component._ceremony_buffs_from_snapshot(self, new_index)


func is_era_ceremony_playing() -> bool:
	return _era_component.is_era_ceremony_playing(self)


func _on_era_ceremony_landed(new_index: int) -> void:
	_era_component._on_era_ceremony_landed(self, new_index)


func _land_era_on_badge(era_name: String) -> void:
	_era_component._land_era_on_badge(self, era_name)


func _on_era_ceremony_finished() -> void:
	_era_component._on_era_ceremony_finished(self)


func _abort_era_ceremony() -> void:
	_era_component._abort_era_ceremony(self)


func _notify_era_promoted(model: Dictionary) -> void:
	_era_component._notify_era_promoted(self, model)


func _on_era_flight_landed() -> void:
	_era_component._on_era_flight_landed(self)


func show_era_reward_error(message: String) -> void:
	_era_component.show_era_reward_error(self, message)


func show_era_reward_pending() -> void:
	_era_component.show_era_reward_pending(self)


func close_era_reward_offer() -> void:
	_era_component.close_era_reward_offer(self)


func is_era_reward_modal_open() -> bool:
	return _era_component.is_era_reward_modal_open(self)


func show_family_founding_offer(offer: Dictionary) -> void:
	_era_component.show_family_founding_offer(self, offer)


func show_family_founding_error(message: String) -> void:
	_era_component.show_family_founding_error(self, message)


func close_family_founding_offer() -> void:
	_era_component.close_family_founding_offer(self)


func is_family_founding_modal_open() -> bool:
	return _era_component.is_family_founding_modal_open(self)


func bind_gm_sun_camera(camera: MapCamera) -> void:
	_overlay_component.bind_gm_sun_camera(self, camera)


func bind_player_camera(camera: MapCamera) -> void:
	_overlay_component.bind_player_camera(self, camera)


func _ensure_gm_sun_handle() -> void:
	_overlay_component._ensure_gm_sun_handle(self)


func _on_gm_sun_camera_moved(_world_rect: Rect2, _center: Vector2, _zoom_value: float) -> void:
	_overlay_component._on_gm_sun_camera_moved(self, _world_rect, _center, _zoom_value)


func _on_gm_tod_preview_changed(_active: bool) -> void:
	_overlay_component._on_gm_tod_preview_changed(self, _active)


func _sync_gm_sun_handle() -> void:
	_overlay_component._sync_gm_sun_handle(self)


func _position_gm_sun_handle() -> void:
	_overlay_component._position_gm_sun_handle(self)


func _on_gm_sun_handle_input(event: InputEvent) -> void:
	_overlay_component._on_gm_sun_handle_input(self, event)


func _apply_gm_sun_drag(screen_pos: Vector2) -> void:
	_overlay_component._apply_gm_sun_drag(self, screen_pos)


func _get_local_gm_toggle_state(toggle_id: String) -> Dictionary:
	return _overlay_component._get_local_gm_toggle_state(self, toggle_id)


func _set_local_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
	return _overlay_component._set_local_gm_toggle(self, toggle_id, enabled)


func _on_runtime_gm_toggle_changed(toggle_id: String, enabled: bool) -> void:
	_overlay_component._on_runtime_gm_toggle_changed(self, toggle_id, enabled)
