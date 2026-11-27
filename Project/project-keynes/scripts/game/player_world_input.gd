extends RefCounted

## Processes world pointer and keyboard input and resolves tile selection.


static func _handle_touch_gm_gesture(owner: PlayerController, event: InputEvent) -> bool:
	var touch := event as InputEventScreenTouch
	if touch == null:
		return false
	if touch.pressed:
		owner._touch_gm_active[touch.index] = true
		if owner._touch_gm_active.size() == 3 and owner._touch_gm_armed_ms == 0:
			owner._touch_gm_armed_ms = Time.get_ticks_msec()
		return false
	owner._touch_gm_active.erase(touch.index)
	if not owner._touch_gm_active.is_empty():
		return false
	if owner._touch_gm_armed_ms == 0:
		return false
	var duration := Time.get_ticks_msec() - owner._touch_gm_armed_ms
	owner._touch_gm_armed_ms = 0
	if duration > PlayerController.TOUCH_GM_TAP_MAX_MS:
		return false
	var now := Time.get_ticks_msec()
	var recent := PackedInt64Array()
	for stamp in owner._touch_gm_tap_times:
		if now - stamp <= PlayerController.TOUCH_GM_DOUBLE_WINDOW_MS:
			recent.append(stamp)
	recent.append(now)
	owner._touch_gm_tap_times = recent
	if owner._touch_gm_tap_times.size() < 2:
		return false
	owner._touch_gm_tap_times.clear()
	owner.WorldInput._toggle_gm_from_gesture(owner)
	# 手势生效，但这次抬手不能吞：它是最后一根手指的 release，被 :672 的 if 吞掉后
	# :677 的 _dispatch_player_input 不会执行，map_camera._handle_screen_touch 的 erase
	# （map_camera.gd:359）被跳过，_touches 残留一个 index。下一次单指按下就凑成
	# count>=2（map_camera.gd:361-363），_pinching/_multitouch_guard 锁死且不会自愈：
	# 单指拖动变成捏合缩放、点按被 :431-432 吞掉。放行后相机自己把 index 擦掉。
	return false



static func _toggle_gm_from_gesture(owner: PlayerController) -> void:
	if owner._ui_manager == null:
		return
	if not owner._ui_manager.is_gm_available():
		print("[input] 三指双击：当前构建 GM 面板不可用（release 包）")
		return
	owner._ui_manager.toggle_gm_panel()
	print("[input] 三指双击 → GM 面板")



static func _dispatch_player_input(owner: PlayerController, event: InputEvent) -> void:
	if not owner._military_order_mode.is_empty():
		var cancel_key := event is InputEventKey and event.is_pressed() \
			and not event.is_echo() and (event.is_action_pressed(&"player_cancel") \
			or event.is_action_pressed(&"ui_cancel"))
		var cancel_mouse: bool = event is InputEventMouseButton and event.is_pressed() \
			and event.button_index == MOUSE_BUTTON_RIGHT
		if cancel_key or cancel_mouse:
			owner.cancel_military_arm_order()
			owner.get_viewport().set_input_as_handled()
			return
	if owner._annual_report_flow.is_open():
		if event.is_action_pressed(&"player_cancel") or event.is_action_pressed(&"ui_cancel"):
			owner._ui_manager.dismiss_overlay_menu()
		owner.get_viewport().set_input_as_handled()
		return
	if owner._camera != null and owner._camera.handle_player_input(event):
		owner.get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	var debug_hotkeys_enabled := OS.is_debug_build()
	if key.is_action_pressed(&"player_pause"):
		if owner._world_clock != null:
			owner._world_clock.toggle_pause()
			owner.sync_ui()
			owner.get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_cancel"):
		if owner._ui_manager != null and not owner._ui_manager.dismiss_overlay_menu():
			owner._ui_manager.toggle_pause_menu()
		owner.get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_fit_view"):
		if debug_hotkeys_enabled and owner._runtime_host != null and owner._ui_manager != null:
			owner._runtime_host.fit_camera(owner._ui_manager.map_safe_area())
			owner.get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_regenerate"):
		# Regeneration remains a scene-lifecycle concern and is intentionally not
		# exposed through the formal player command surface.
		if debug_hotkeys_enabled:
			owner.regeneration_requested.emit()
			owner.get_viewport().set_input_as_handled()
	elif key.keycode == KEY_QUOTELEFT \
			or key.is_action_pressed(&"player_open_gm"):
		if debug_hotkeys_enabled and owner._ui_manager != null and owner._ui_manager.is_gm_available():
			owner._ui_manager.toggle_gm_panel()
			owner.get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_perf_hud"):
		if debug_hotkeys_enabled and owner._ui_manager != null:
			owner._ui_manager.toggle_perf_hud()
			owner.get_viewport().set_input_as_handled()
	elif key.keycode == KEY_Y and not (key.ctrl_pressed or key.alt_pressed or key.meta_pressed):
		# 资源透镜：把世界里的资源/物种实景切换为统一的识别徽章，便于一眼找到产区。
		var renderer: Node = owner._runtime_host.get_renderer() if owner._runtime_host != null else null
		if renderer != null and renderer.has_method("set_resource_visual_lens"):
			renderer.set_resource_visual_lens(not renderer.resource_visual_lens_enabled())
			owner.get_viewport().set_input_as_handled()



static func _on_tile_tapped(owner: PlayerController, world_pos: Vector2) -> void:
	if owner._runtime_host == null or owner._runtime_host.current_map() == null:
		return
	var cell: Variant = HexUtils.world_to_wrapped_cell(owner._runtime_host.current_map(), world_pos,
		owner._runtime_host.hex_size)
	# 议和窗口开着时地图就是「交割选格」：部队/战线拾取必须让路，否则停在候选格上的
	# 部队棋子会先抢走这次点击。
	if owner.WorldInput._peace_window_open(owner):
		if cell != null:
			owner.select_cell(cell)
		return
	# 部队指令模式下地图点击是目标格，保持旧语义；否则先给军务档案一次拾取机会。
	if owner._military_order_mode.is_empty() and cell != null and owner.military_map_pick(world_pos):
		return
	if owner._military_order_mode.is_empty() and owner._cell_situation_picker.is_valid() and owner._camera != null:
		var alert_cell := int(owner._cell_situation_picker.call(owner._camera.safe_world_to_screen(world_pos)))
		if alert_cell >= 0:
			cell = owner._runtime_host.current_map().cell_at(alert_cell)
	if cell != null:
		owner.select_cell(cell)


## True while the peace window owns map clicks (see select_cell / _on_tile_tapped).
static func _peace_window_open(owner: PlayerController) -> bool:
	return owner._ui_manager != null and owner._ui_manager.has_method("is_peace_window_open") \
		and bool(owner._ui_manager.call("is_peace_window_open"))
