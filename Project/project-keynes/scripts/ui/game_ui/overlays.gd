extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _ensure_cell_hover_card(host) -> void:
	if host._cell_hover_card != null:
		return
	var hud := host.get_node_or_null("UIRoot/HUDLayer") as Control
	if hud == null:
		return
	var card := host.CellHoverCardScene.instantiate() as CellHoverCard
	if card == null:
		return
	card.name = "CellHoverCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(card)
	host._cell_hover_card = card
	host._configure_cell_hover_card()


func _on_military_layer_toggled(host, layer_id: StringName, enabled: bool) -> void:
	if host._diagnostics_source == null:
		return
	var layers = host._diagnostics_source.get("military_map_layers")
	if layers != null and layers.has_method("set_layer_visibility"):
		layers.set_layer_visibility(layer_id, enabled)


func _on_map_overlay_requested(host, request: Dictionary) -> void:
	var mode := int(request.get("mode", OverlayMode.MODE.NONE))
	var title := ""
	var icon_key := ""
	var hint := ""
	var occupancy_bit := -1
	if mode == OverlayMode.MODE.RESOURCE_RESERVE:
		var resource_id := StringName(request.get("resource_id", &""))
		for profile in ResourceProfileRegistry.ordered():
			if profile != null and profile.id == resource_id:
				title = profile.display_name
				icon_key = ResourceProfileRegistry.icon_key(profile)
				break
	elif mode == OverlayMode.MODE.BIO_OCCUPANCY:
		var signal_id := StringName(request.get("signal_id", &""))
		for entry in ResearchSignalCatalog.occupancy_overlay_entries():
			if StringName(entry.get("id", &"")) == signal_id:
				title = String(entry.get("display_name", ""))
				icon_key = String(entry.get("icon_key", &"ecology.growth"))
				occupancy_bit = int(entry.get("occupancy_bit", -1))
				break
	if host._map_overlay_legend != null:
		host._map_overlay_legend.update_for_mode(mode, title, hint, icon_key, occupancy_bit)
		host.call_deferred("_layout_overlay_legend")
	host.map_overlay_requested.emit(request)


func _on_map_overlay_cleared(host) -> void:
	if host._map_overlay_legend != null:
		host._map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	host.map_overlay_cleared.emit()

func bind_gm_sun_camera(host, camera: MapCamera) -> void:
	if host._gm_sun_camera != null and host._gm_sun_camera.view_changed.is_connected(host._on_gm_sun_camera_moved):
		host._gm_sun_camera.view_changed.disconnect(host._on_gm_sun_camera_moved)
	host._gm_sun_camera = camera
	if host._gm_sun_camera != null and not host._gm_sun_camera.view_changed.is_connected(host._on_gm_sun_camera_moved):
		host._gm_sun_camera.view_changed.connect(host._on_gm_sun_camera_moved)


## 悬停卡需要读玩家相机的屏幕→世界换算与平移/缩放状态。
## PlayerGame 在建图前就会调用，所以这里必须容忍 _map 尚未就绪。

func bind_player_camera(host, camera: MapCamera) -> void:
	host._player_camera = camera
	host._configure_cell_hover_card()



func _ensure_gm_sun_handle(host) -> void:
	if host._gm_sun_handle != null and is_instance_valid(host._gm_sun_handle):
		return
	host._gm_sun_handle = UIControlParts.button()
	host._gm_sun_handle.name = "GMTODSunHandle"
	host._gm_sun_handle.text = "☀"
	host._gm_sun_handle.tooltip_text = "拖动太阳位置"
	host._gm_sun_handle.custom_minimum_size = Vector2(38.0, 38.0)
	host._gm_sun_handle.size = Vector2(38.0, 38.0)
	host._gm_sun_handle.focus_mode = Control.FOCUS_NONE
	host._gm_sun_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	host._gm_sun_handle.visible = false
	host._gm_sun_handle.z_index = 20
	host._gm_sun_handle.gui_input.connect(host._on_gm_sun_handle_input)
	host.add_child(host._gm_sun_handle)



func _on_gm_sun_camera_moved(host, _world_rect: Rect2, _center: Vector2, _zoom_value: float) -> void:
	host._position_gm_sun_handle()



func _on_gm_tod_preview_changed(host, _active: bool) -> void:
	host._sync_gm_sun_handle()



func _sync_gm_sun_handle(host) -> void:
	var preview = false
	if host._diagnostics_source != null and host._diagnostics_source.has_method("get_gm_tod_sun_preview"):
		var state: Variant = host._diagnostics_source.call("get_gm_tod_sun_preview")
		if state is Dictionary:
			preview = bool(state.get("preview", false))
	host._ensure_gm_sun_handle()
	host._gm_sun_handle.visible = preview
	if host._gm_sun_handle.visible and not host._gm_sun_dragging:
		host._position_gm_sun_handle()



func _position_gm_sun_handle(host) -> void:
	if host._gm_sun_handle == null or not host._gm_sun_handle.visible:
		return
	if host._diagnostics_source == null or not host._diagnostics_source.has_method("gm_tod_sun_screen_position"):
		return
	var screen: Vector2 = host._diagnostics_source.call("gm_tod_sun_screen_position")
	if not is_finite(screen.x) or not is_finite(screen.y):
		return
	host._gm_sun_handle.position = screen - host._gm_sun_handle.size * 0.5



func _on_gm_sun_handle_input(host, event: InputEvent) -> void:
	if host._diagnostics_source == null or not host._diagnostics_source.has_method("set_gm_tod_sun_preview"):
		return
	if event is InputEventMouseButton:
		var button = event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		host._gm_sun_dragging = button.pressed
		if button.pressed:
			host._apply_gm_sun_drag(host.get_viewport().get_mouse_position())
		else:
			host._sync_gm_sun_handle()
		host._gm_sun_handle.accept_event()
	elif event is InputEventMouseMotion and host._gm_sun_dragging:
		host._apply_gm_sun_drag(host.get_viewport().get_mouse_position())
		host._gm_sun_handle.accept_event()
	elif event is InputEventScreenTouch:
		var touch = event as InputEventScreenTouch
		host._gm_sun_dragging = touch.pressed
		if touch.pressed:
			host._apply_gm_sun_drag(touch.position)
		else:
			host._sync_gm_sun_handle()
		host._gm_sun_handle.accept_event()
	elif event is InputEventScreenDrag and host._gm_sun_dragging:
		host._apply_gm_sun_drag((event as InputEventScreenDrag).position)
		host._gm_sun_handle.accept_event()



func _apply_gm_sun_drag(host, screen_pos: Vector2) -> void:
	var height = 1.0
	var uv = Vector2(0.25, 0.5)
	if host._diagnostics_source.has_method("get_gm_tod_sun_preview"):
		var state: Variant = host._diagnostics_source.call("get_gm_tod_sun_preview")
		if state is Dictionary:
			height = float(state.get("height_scale", 1.0))
			var current: Variant = state.get("uv", uv)
			if current is Vector2:
				uv = current
	if host._diagnostics_source.has_method("gm_tod_screen_to_sun_uv"):
		uv = host._diagnostics_source.call("gm_tod_screen_to_sun_uv", screen_pos)
	host._diagnostics_source.call("set_gm_tod_sun_preview", true, uv, height)
	if host._gm_sun_handle != null:
		host._gm_sun_handle.position = screen_pos - host._gm_sun_handle.size * 0.5



func _get_local_gm_toggle_state(host, toggle_id: String) -> Dictionary:
	if toggle_id == "diagnostics.perf_hud" and host._perf_hud != null:
		return {"ok": true, "enabled": host._perf_hud.visible}
	return {"ok": false, "message": "未知本地 GM 开关。"}



func _set_local_gm_toggle(host, toggle_id: String, enabled: bool) -> Dictionary:
	if toggle_id != "diagnostics.perf_hud" or host._perf_hud == null:
		return {"ok": false, "message": "未知本地 GM 开关。"}
	if host._perf_hud.visible != enabled:
		host._perf_hud.toggle_visible()
	return {"ok": true, "enabled": host._perf_hud.visible, "message": "Perf HUD 已更新。"}



func _on_runtime_gm_toggle_changed(host, toggle_id: String, enabled: bool) -> void:
	if toggle_id == "visual.day_night":
		host.set_day_night_enabled(enabled)



func show_annual_report(host, model: Dictionary, ceremonial: bool) -> void:
	if host._annual_report_workspace != null:
		host._annual_report_workspace.present(model, ceremonial)



func set_annual_history(host, rows: Array, offset: int, has_more: bool) -> void:
	if host._annual_report_workspace != null:
		host._annual_report_workspace.set_history(rows, offset, has_more)



func is_annual_report_open(host) -> bool:
	return host._annual_report_workspace != null and host._annual_report_workspace.visible



func close_annual_report(host) -> void:
	if host._annual_report_workspace != null and host._annual_report_workspace.has_method("_close"):
		host._annual_report_workspace.call("_close")



func annual_other_modal_open(host) -> bool:
	return host.is_era_reward_modal_open() or host.is_family_founding_modal_open() \
		or host.is_narrative_event_modal_open() \
		or (host._pause_menu != null and host._pause_menu.visible)



func show_narrative_event_offer(host, offer: Dictionary) -> void:
	host._ensure_narrative_ui()
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.close_panel()
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("present_offer"):
		host._narrative_event_dialog.present_offer(offer)



func show_narrative_event_outcome(host, resolution: Dictionary) -> void:
	host._ensure_narrative_ui()
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("show_outcome"):
		host._narrative_event_dialog.show_outcome(resolution)



func show_narrative_event_error(host, message: String) -> void:
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("show_error"):
		host._narrative_event_dialog.show_error(message)



func set_narrative_event_illustration(host, tex: Texture2D) -> void:
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("set_illustration_texture"):
		host._narrative_event_dialog.set_illustration_texture(tex)



func close_narrative_event_offer(host) -> void:
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("close_offer"):
		host._narrative_event_dialog.close_offer()



func is_narrative_event_modal_open(host) -> bool:
	return host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("is_offer_open") \
		and bool(host._narrative_event_dialog.is_offer_open())



func show_narrative_chronicle(host, records: Array) -> void:
	host._ensure_narrative_ui()
	if host._narrative_chronicle_panel != null and host._narrative_chronicle_panel.has_method("open_panel"):
		host._narrative_chronicle_panel.open_panel(records)



func close_narrative_chronicle(host) -> void:
	if host._narrative_chronicle_panel != null and host._narrative_chronicle_panel.has_method("close_panel"):
		host._narrative_chronicle_panel.close_panel()



func is_narrative_chronicle_open(host) -> bool:
	return host._narrative_chronicle_panel != null and host._narrative_chronicle_panel.visible




func set_popups_suppressed(host, enabled: bool) -> void:
	host._gm_popups_suppressed = enabled
	if not enabled:
		return
	if host.is_era_ceremony_playing():
		host._era_ceremony.skip()
	if host._narrative_event_dialog != null and host._narrative_event_dialog.has_method("close_offer"):
		host._narrative_event_dialog.close_offer()

func dismiss_overlay_menu(host) -> bool:
	if host._player_controller != null and not String(
			host._player_controller.military_arm_order().get("mode", "")).is_empty():
		host._player_controller.cancel_military_arm_order()
		return true
	if host._status_card != null and host._status_card.is_open():
		host._status_card_generation += 1
		host._status_card_kind = ""
		host._status_card.hide_card(true)
		return true
	if host.is_era_ceremony_playing():
		host._era_ceremony.skip()
		return true
	if host.is_annual_report_open():
		host._annual_report_workspace.call("_close")
		return true
	if host._era_reward_dialog != null and host._era_reward_dialog.visible:
		host._on_era_popup_dismissed()
		return true
	if host._era_panel != null and host._era_panel.is_open():
		host._close_era_panel()
		return true
	if host.is_family_founding_modal_open():
		if host._right_panel != null and host._right_panel.detail_open():
			host._right_panel.close_detail()
			return true
		if host._family_founding_dialog != null:
			host._family_founding_dialog.toggle_collapsed()
		return true
	if host._colonization_panel != null and (host._colonization_panel.is_source_picking() \
			or host._colonization_panel.is_target_picking()):
		host._cancel_colonization_targeting()
		return true
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.close_panel()
		return true
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
		return true
	if host._gm_console != null and host._gm_console.is_panel_open():
		host._gm_console.close_panel()
		return true
	if host._map_overlay_toolbar != null and host._map_overlay_toolbar.dismiss_submenu():
		return true
	if host._right_panel != null and host._right_panel.visible:
		if host._right_panel.detail_open():
			host._right_panel.close_detail()
			return true
		host.clear_selection_requested.emit()
		return true
	return false

func toggle_pause_menu(host) -> void:
	if host._player_controller != null:
		host._player_controller.cancel_military_arm_order()
	if host._pause_menu != null and not host.is_era_reward_modal_open() \
			and not host.is_family_founding_modal_open():
		host._pause_menu.toggle()


func set_all_ui_suppressed(host, enabled: bool) -> void:
	if host._gm_all_ui_suppressed == enabled:
		return
	host._gm_all_ui_suppressed = enabled
	var paths := ["UIRoot/HUDLayer", "UIRoot/PanelLayer", "UIRoot/ModalLayer",
		"UIRoot/EraOverlayLayer"]
	if enabled:
		host._gm_saved_ui_visibility.clear()
		for path in paths:
			var node := host.get_node_or_null(path) as CanvasItem
			if node == null:
				continue
			host._gm_saved_ui_visibility[path] = node.visible
			node.visible = false
		# DebugLayer 可能包含旧的诊断控件；只保留 GM 面板可见。
		if host._debug_layer != null:
			for child in host._debug_layer.get_children():
				if child != host._gm_console and child is CanvasItem:
					var key := String(child.get_path())
					host._gm_saved_ui_visibility[key] = (child as CanvasItem).visible
					(child as CanvasItem).visible = false
			if host._gm_console != null:
				host._gm_console.visible = true
	else:
		for path in paths:
			if host._gm_saved_ui_visibility.has(path):
				var restore_node := host.get_node_or_null(path) as CanvasItem
				if restore_node != null:
					restore_node.visible = bool(host._gm_saved_ui_visibility[path])
		if host._debug_layer != null:
			for child in host._debug_layer.get_children():
				var key := String(child.get_path())
				if host._gm_saved_ui_visibility.has(key) and child is CanvasItem:
					(child as CanvasItem).visible = bool(host._gm_saved_ui_visibility[key])
		host._gm_saved_ui_visibility.clear()
	host._layout_gm_panel()


func _hud_layout(host):
	host._hud_layout_component._colonization_panel = host._colonization_panel
	host._hud_layout_component._country_action_bar = host._country_action_bar
	host._hud_layout_component._family_founding_dialog = host._family_founding_dialog
	host._hud_layout_component._gm_console = host._gm_console
	host._hud_layout_component._map_overlay_legend = host._map_overlay_legend
	host._hud_layout_component._map_overlay_toolbar = host._map_overlay_toolbar
	host._hud_layout_component._military_dossier_context = host._military_dossier_context
	host._hud_layout_component._peace_window = host._peace_window
	host._hud_layout_component._research_toast = host._research_toast
	host._hud_layout_component._right_panel = host._right_panel
	host._hud_layout_component._top_bar = host._top_bar
	host._hud_layout_component._viewport = host.get_viewport()
	host._hud_layout_component._window = host.get_window()
	host._hud_layout_component._ui_root = host.get_node_or_null("UIRoot") as Control
	host._hud_layout_component._settings = host.get_node_or_null("/root/GameSettings")
	return host._hud_layout_component

# G5 responsibility adapters. Mutable state remains in this host.


func toggle_gm_panel(host) -> void:
	if not host._gm_available or host._gm_console == null:
		return
	if host._gm_console.is_panel_open():
		host._gm_console.close_panel()
	else:
		host._gm_console.open_panel()


func toggle_perf_hud(host) -> void:
	if host._perf_hud != null:
		host._perf_hud.toggle_visible()


func is_gm_available(host) -> bool:
	return host._gm_available and host._gm_console != null


func set_colonization_route_layer(host, layer: ColonizationRouteLayer) -> void:
	host._colonization_route = layer


func _configure_cell_hover_card(host) -> void:
	if host._cell_hover_card == null or host._map == null or host._cell_hover_view_model == null:
		return
	host._cell_hover_card.configure(host._map, host._player_camera, host._hover_hex_size,
		host._cell_hover_view_model, host._hover_blocked, host.map_safe_area)


func touch_layout_enabled(host) -> bool:
	return host._hud_layout().touch_layout_enabled()


## 递归打印子控件 rect（只在 panel-diag 触发一次）。


func update_time_state(host, year_idx: int,
		month: int,
		day_of_month: int,
		paused: bool,
		speed: float) -> void:
	if host._top_bar != null:
		host._top_bar.update_time_state(
			year_idx,
			month,
			day_of_month,
			paused,
			speed
		)


func set_world_summary(host, width: int, height: int, cells: int, seed: int) -> void:
	if host._top_bar != null:
		host._top_bar.set_world_summary(width, height, cells, seed)


func set_day_night_enabled(host, enabled: bool) -> void:
	if host._top_bar != null:
		host._top_bar.set_day_night_enabled(enabled)


func show_loading(host, message: String) -> void:
	if host._loading_overlay != null:
		host._loading_overlay.show_message(message)


func set_generation_progress(host, stage: String, fraction: float) -> void:
	if host._loading_overlay != null:
		host._loading_overlay.set_progress(stage, fraction)


func hide_loading(host) -> void:
	if host._loading_overlay != null:
		host._loading_overlay.hide_completed()


func show_exit_save_failure(host, action: String, result: Dictionary) -> void:
	if host._pause_menu != null:
		host._pause_menu.show_save_failure(action, result)
