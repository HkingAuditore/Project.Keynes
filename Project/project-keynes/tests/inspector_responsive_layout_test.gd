extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	_check_wide(failures, 1920.0, 1040.0)
	_check_wide(failures, 1366.0, 860.0)
	_check_wide(failures, 1180.0, 860.0)
	_check_compact(failures, 1179.0)
	_check_compact(failures, 1024.0)
	var closed := GameUIManager.inspector_layout_for_width(1024.0, false)
	if bool(closed.get("compact", false)) != true \
			or not is_equal_approx(float(closed.get("panel_width", 0.0)), 460.0):
		failures.append("closed Inspector did not keep its 460px dossier width")
	await _check_scene_geometry(failures)
	if failures.is_empty():
		print("[inspector-responsive-layout] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[inspector-responsive-layout] FAIL: %s" % failure)
		quit(1)


func _check_wide(failures: PackedStringArray, viewport_width: float,
		expected_width: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(viewport_width, true)
	if bool(layout.get("compact", true)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), expected_width) \
			or float(layout.get("detail_width", 0.0)) < 400.0 \
			or float(layout.get("detail_width", 9999.0)) > 580.0 \
			or float(layout.get("map_width", 0.0)) < 320.0:
		failures.append("%.0fpx did not produce the expected two-column layout" % viewport_width)


func _check_compact(failures: PackedStringArray, viewport_width: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(viewport_width, true)
	if not bool(layout.get("compact", false)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), viewport_width) \
			or not is_zero_approx(float(layout.get("map_width", -1.0))):
		failures.append("%.0fpx did not produce the full content drawer" % viewport_width)


func _check_scene_geometry(failures: PackedStringArray) -> void:
	var root := Control.new()
	root.size = Vector2(1920.0, 720.0)
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(panel)
	panel.visible = true
	panel._detail_shell.visible = true
	panel._inspector_root.visible = true
	for panel_width in [860.0, 1040.0]:
		panel.custom_minimum_size.x = panel_width
		panel.offset_left = -panel_width
		await process_frame
		var expected_detail: float = float(panel_width) - 460.0
		if not is_equal_approx(panel.size.x, panel_width) \
				or not is_equal_approx(panel._detail_shell.size.x, expected_detail) \
				or not is_equal_approx(panel._inspector_root.size.x, 424.0):
			failures.append("%.0fpx scene columns are not %.0f/424: detail=%s dossier=%s" % [
				panel_width, expected_detail, panel._detail_shell.size,
				panel._inspector_root.size])
		panel._object_detail_dialog.set_embedded(true)
		panel._object_detail_dialog.visible = true
		await process_frame
		var dialog := panel._object_detail_dialog.get_node("Center/Dialog") as Control
		if not dialog.size.is_equal_approx(panel._object_detail_dialog.size) \
				or dialog.size.x < expected_detail - 16.0:
			failures.append("%.0fpx embedded object detail did not fill its workspace: dialog=%s root=%s shell=%s" % [
				panel_width, dialog.size, panel._object_detail_dialog.size,
				panel._detail_shell.size])
