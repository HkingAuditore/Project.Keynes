extends SceneTree

# Headless integration smoke:
# godot --headless --path . --script tests/player_map_overlay_smoke_test.gd

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var game := packed.instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	runtime.set_map_overlay({
		"mode": OverlayMode.MODE.ELEVATION,
		"resource_id": &"",
	})
	await process_frame
	await process_frame

	var overlay_layer := game.get_node("WorldRoot/DataOverlayLayer")
	var diag := runtime.map_overlay_diagnostics()
	var result: Dictionary = diag.get("last_result", {})
	_expect("overlay is active", bool(diag.get("active", false)))
	_expect("player path is cell LUT", String(result.get("path", "")) == "cell_lut")
	_expect("upload is LUT-sized", int(result.get("upload_bytes", 0)) ==
		runtime.world_data().lut_dims.x * runtime.world_data().lut_dims.y * 4)
	_expect("encode and upload stay below legacy warning threshold",
		float(result.get("encode_upload_ms", 999.0)) < 5.0)
	_expect("overlay mode applied to layer",
		overlay_layer.get_mode() == OverlayMode.MODE.ELEVATION)
	if DisplayServer.get_name() != "headless":
		_expect("overlay quad visible", overlay_layer.visible)
	var toolbar := game.get_node_or_null("UI/UIRoot/HUDLayer/MapOverlayToolbar") as MapOverlayToolbar
	_expect("toolbar exists", toolbar != null)
	if toolbar != null:
		toolbar.call("_set_category", MapOverlayToolbar.Category.RESOURCES)
		await process_frame
		await process_frame
		var layout: Dictionary = toolbar.layout_diagnostics()
		_expect("resource submenu height is capped",
			float(layout.get("secondary_height", 9999.0)) <= 430.0)
		_expect("close layer action stays visible", bool(layout.get("close_visible", false)))
		_assert_opening_discovery_filters(toolbar)
		_assert_overlay_buttons_do_not_steal_focus(toolbar)
		toolbar.call("_set_category", MapOverlayToolbar.Category.BIOLOGY)
		await process_frame
		await process_frame
		var biology_layout: Dictionary = toolbar.layout_diagnostics()
		_expect("biology submenu height is capped",
			float(biology_layout.get("secondary_height", 9999.0)) <= 430.0)
		_expect("biology close layer action stays visible",
			bool(biology_layout.get("close_visible", false)))
		_assert_opening_biology_stays_unnamed(toolbar)
		_assert_leftover_hud_focus_does_not_lock_map(game)
		var legend := game.get_node_or_null("UI/UIRoot/HUDLayer/MapOverlayLegend") as Control
		if legend != null:
			var legend_rect := Rect2(legend.global_position, legend.size)
			var secondary_rect: Rect2 = biology_layout.get("secondary_rect", Rect2())
			_expect("legend does not overlap submenu",
				not legend_rect.intersects(secondary_rect))
			_expect("legend is docked below the map reading line",
				legend_rect.get_center().y > root.get_viewport().get_visible_rect().size.y * 0.5)
			var right_panel := game.get_node_or_null("UI/UIRoot/PanelLayer/RightPanel") as Control
			if right_panel != null:
				right_panel.visible = true
				await process_frame
				var shifted_legend_rect := Rect2(legend.global_position, legend.size)
				var right_panel_rect := Rect2(right_panel.global_position, right_panel.size)
				_expect("legend shifts left of visible inspector",
					not shifted_legend_rect.intersects(right_panel_rect))
				right_panel.visible = false
	runtime.set_map_overlay({
		"mode": OverlayMode.MODE.RESOURCE_RESERVE,
		"resource_id": &"timber",
	})
	var resource_diag := runtime.map_overlay_diagnostics()
	var resource_stats: Dictionary = resource_diag.get("last_result", {}).get("stats", {})
	print("  [INFO] timber overlay stats=%s" % str(resource_stats))
	_expect("resource overlay has visible dynamic range",
		float(resource_stats.get("max", 0.0)) - float(resource_stats.get("min", 0.0)) > 0.10)
	var map := runtime.current_map()
	var catalog := ResearchSignalCatalog.compile_native_catalog()
	var maize_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.maize")
	_expect("maize occupancy bit is valid", maize_bit >= 0)
	if map != null and map.bio_occupancy_bits_arr.size() > 0 and maize_bit >= 0:
		map.bio_occupancy_bits_arr[0] = int(map.bio_occupancy_bits_arr[0]) | (1 << maize_bit)
	runtime.set_map_overlay({
		"mode": OverlayMode.MODE.BIO_OCCUPANCY,
		"signal_id": &"bio.maize",
	})
	var biology_diag := runtime.map_overlay_diagnostics()
	var biology_result: Dictionary = biology_diag.get("last_result", {})
	var biology_stats: Dictionary = biology_result.get("stats", {})
	print("  [INFO] maize overlay stats=%s" % str(biology_stats))
	_expect("biology overlay uses cell LUT", String(biology_result.get("path", "")) == "cell_lut")
	_expect("biology overlay has occupied cells", int(biology_stats.get("count", 0)) > 0)
	diag = biology_diag
	var refresh_before := int(diag.get("refresh_count", 0))
	runtime.mark_map_overlay_dirty(&"test_a")
	runtime.mark_map_overlay_dirty(&"test_b")
	runtime.mark_map_overlay_dirty(&"test_c")
	_expect("dirty events merge", int(runtime.map_overlay_diagnostics().get(
		"merged_dirty_count", 0)) >= 2)
	await _await_real_msec(120)
	var refresh_delta := int(runtime.map_overlay_diagnostics().get(
		"refresh_count", 0)) - refresh_before
	_expect("merged dirty avoids per-event refresh fanout",
		refresh_delta >= 1 and refresh_delta <= 2)
	runtime.clear_map_overlay()
	await create_timer(0.2).timeout
	_expect("clear hides overlay", not game.get_node("WorldRoot/DataOverlayLayer").visible)
	var refresh_after_clear := int(runtime.map_overlay_diagnostics().get("refresh_count", 0))
	await create_timer(0.12).timeout
	_expect("closed overlay stops refreshing", int(runtime.map_overlay_diagnostics().get(
		"refresh_count", 0)) == refresh_after_clear)

	print("=== player map overlay smoke: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _assert_opening_discovery_filters(toolbar: MapOverlayToolbar) -> void:
	var technology_ids: PackedStringArray = toolbar.get("_technology_ids")
	_expect("player overlay enforces discovery",
		bool(toolbar.get("_enforce_discovery"))
		and technology_ids.has("tech.gathering")
		and technology_ids.has("tech.hunting"))
	var named_ids := {}
	for profile in ResourceProfileRegistry.ordered():
		if profile == null:
			continue
		if ResourceProfileRegistry.discovery_visible(profile, technology_ids):
			named_ids[String(profile.id)] = true
	_expect("opening overlay names fertile soil and wild game",
		named_ids.has("fertile_soil") and named_ids.has("wild_game"))
	_expect("opening overlay does not name unidentified minerals or timber",
		not named_ids.has("iron_ore")
		and not named_ids.has("copper_ore")
		and not named_ids.has("coal")
		and not named_ids.has("flint")
		and not named_ids.has("timber"))
	_expect("resource buttons match discovery-visible deposits",
		(toolbar.get("_mode_buttons") as Array).size() == named_ids.size())


func _assert_opening_biology_stays_unnamed(toolbar: MapOverlayToolbar) -> void:
	var technology_ids: PackedStringArray = toolbar.get("_technology_ids")
	var compiled: Dictionary = TechnologyCatalog.compile_native_catalog()
	var named_count := 0
	for entry in ResearchSignalCatalog.occupancy_overlay_entries():
		if TechnologyCatalog.signal_named_by_completed_technologies(
				String(entry.get("id", "")), technology_ids, compiled):
			named_count += 1
	_expect("opening overlay does not name unidentified species",
		not TechnologyCatalog.signal_named_by_completed_technologies(
			"bio.maize", technology_ids, compiled)
		and not TechnologyCatalog.signal_named_by_completed_technologies(
			"bio.flax", technology_ids, compiled)
		and not TechnologyCatalog.signal_named_by_completed_technologies(
			"bio.sheep", technology_ids, compiled))
	_expect("biology buttons match named occupancy signals",
		(toolbar.get("_mode_buttons") as Array).size() == named_count)


func _assert_overlay_buttons_do_not_steal_focus(toolbar: MapOverlayToolbar) -> void:
	var mode_buttons: Array = toolbar.get("_mode_buttons")
	_expect("resource mode buttons exist", not mode_buttons.is_empty())
	var all_none := true
	for button in mode_buttons:
		if button.focus_mode != Control.FOCUS_NONE:
			all_none = false
			break
	_expect("overlay mode buttons use FOCUS_NONE", all_none)
	if not mode_buttons.is_empty():
		var first: Button = mode_buttons[0]
		_expect("overlay mode button cannot keep viewport focus",
			first.focus_mode == Control.FOCUS_NONE
			and first.get_viewport().gui_get_focus_owner() != first)


func _assert_leftover_hud_focus_does_not_lock_map(game: Node) -> void:
	var controller = game.get_node_or_null("PlayerController")
	var camera = game.get_node_or_null("MapCamera")
	var hud := game.get_node_or_null("UI/UIRoot/HUDLayer") as Control
	if controller == null or camera == null or hud == null:
		_expect("player controller camera and HUD exist for focus gate test", false)
		return
	var leftover := Button.new()
	leftover.focus_mode = Control.FOCUS_ALL
	leftover.custom_minimum_size = Vector2(8, 8)
	hud.add_child(leftover)
	leftover.grab_focus()
	_expect("dummy HUD button can take leftover focus",
		game.get_viewport().gui_get_focus_owner() == leftover)
	camera.zoom = Vector2.ONE
	camera.set("_target_zoom", Vector2.ONE)
	var zoom_before := float(camera.get("_target_zoom").x)
	var wheel_up := InputEventMouseButton.new()
	wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_up.pressed = true
	wheel_up.position = Vector2(640, 360)
	controller._unhandled_input(wheel_up)
	_expect("unhandled map wheel is not blocked by leftover HUD button focus",
		not is_equal_approx(float(camera.get("_target_zoom").x), zoom_before))
	_expect("world pointer event releases leftover HUD focus",
		game.get_viewport().gui_get_focus_owner() == null)
	leftover.grab_focus()
	var zoom_mid := float(camera.get("_target_zoom").x)
	var wheel_down := InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	wheel_down.position = Vector2(640, 360)
	controller.handle_input(wheel_down)
	_expect("direct dispatch stays blocked while ordinary Control has focus",
		is_equal_approx(float(camera.get("_target_zoom").x), zoom_mid))
	var editor := LineEdit.new()
	hud.add_child(editor)
	editor.grab_focus()
	var zoom_text := float(camera.get("_target_zoom").x)
	controller._unhandled_input(wheel_up)
	_expect("text editing still blocks unhandled map gestures",
		is_equal_approx(float(camera.get("_target_zoom").x), zoom_text))
	leftover.queue_free()
	editor.queue_free()


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _await_real_msec(duration_msec: int) -> void:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < duration_msec:
		await process_frame
