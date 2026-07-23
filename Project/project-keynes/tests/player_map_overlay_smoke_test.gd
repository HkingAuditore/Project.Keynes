extends SceneTree

# Headless integration smoke:
# godot --headless --path . --script tests/player_map_overlay_smoke_test.gd

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
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

	var diag := runtime.map_overlay_diagnostics()
	var result: Dictionary = diag.get("last_result", {})
	_expect("overlay is active", bool(diag.get("active", false)))
	_expect("player path is cell LUT", String(result.get("path", "")) == "cell_lut")
	_expect("upload is LUT-sized", int(result.get("upload_bytes", 0)) ==
		runtime.world_data().lut_dims.x * runtime.world_data().lut_dims.y * 4)
	_expect("encode and upload stay below legacy warning threshold",
		float(result.get("encode_upload_ms", 999.0)) < 5.0)
	_expect("overlay quad visible", game.get_node("WorldRoot/DataOverlayLayer").visible)
	var toolbar := game.get_node_or_null("UI/MapOverlayToolbar") as MapOverlayToolbar
	_expect("toolbar exists", toolbar != null)
	if toolbar != null:
		toolbar.call("_set_category", MapOverlayToolbar.Category.RESOURCES)
		await process_frame
		await process_frame
		var layout: Dictionary = toolbar.layout_diagnostics()
		_expect("resource submenu height is capped",
			float(layout.get("secondary_height", 9999.0)) <= 430.0)
		_expect("resource submenu is actually scrollable",
			float(layout.get("scroll_max", 0.0)) > float(layout.get("scroll_page", 0.0)))
		_expect("close layer action stays visible", bool(layout.get("close_visible", false)))
		var legend := game.get_node_or_null("UI/MapOverlayLegend") as Control
		if legend != null:
			var legend_rect := Rect2(legend.global_position, legend.size)
			var secondary_rect: Rect2 = layout.get("secondary_rect", Rect2())
			_expect("legend does not overlap submenu",
				not legend_rect.intersects(secondary_rect))
			_expect("legend is docked below the map reading line",
				legend_rect.get_center().y > root.get_viewport().get_visible_rect().size.y * 0.5)
			var right_panel := game.get_node_or_null("UI/RightPanel") as Control
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
	diag = resource_diag
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
