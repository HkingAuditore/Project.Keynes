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
	_check_family_layout(failures, 1920.0, 960.0, false)
	_check_family_layout(failures, 1366.0, 683.0, false)
	_check_family_layout(failures, 1280.0, 640.0, false)
	_check_family_layout(failures, 1279.0, 1279.0, true)
	_check_family_layout(failures, 1024.0, 1024.0, true)
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


func _check_family_layout(failures: PackedStringArray, viewport_width: float,
		expected_width: float, expected_compact: bool) -> void:
	var layout := GameUIManager.inspector_layout_for_width(
		viewport_width, true, true)
	if bool(layout.get("compact", not expected_compact)) != expected_compact \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), expected_width) \
			or not is_equal_approx(float(layout.get("detail_width", 0.0)), expected_width) \
			or not is_equal_approx(float(layout.get("map_width", -1.0)),
				0.0 if expected_compact else viewport_width * 0.5):
		failures.append("%.0fpx family workspace did not follow 50:50/fullscreen rule: %s" % [
			viewport_width, layout])


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
	panel._sync_split_layout()
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
		if panel_width == 860.0:
			panel.show_object_detail(_family_detail_payload())
			await process_frame
			await process_frame
			_check_family_split(failures, panel, expected_detail)
			panel.close_detail(false)
			panel.show_family_workspace(CellInspectorViewModel.family_workspace_model(
				_family_detail_payload()), false)
			await process_frame
			if not panel.family_workspace_open() or panel._inspector_root.visible \
					or panel._detail_shell.size.x < panel_width - 30.0:
				failures.append("specialized family workspace did not replace the dossier column")
			var root_style := panel.get_theme_stylebox(&"panel")
			var shell_style := panel._detail_shell.get_theme_stylebox(&"panel")
			var outer_margin := panel.get_node("Margin") as MarginContainer
			if not root_style is StyleBoxEmpty or not shell_style is StyleBoxEmpty \
					or outer_margin.get_theme_constant(&"margin_top") != 0 \
					or outer_margin.get_theme_constant(&"margin_bottom") != 0:
				failures.append("family workspace retained the generic black inspector chrome")
			panel.close_detail(false)
			if panel.get_theme_stylebox(&"panel") is StyleBoxEmpty \
					or panel._detail_shell.get_theme_stylebox(&"panel") is StyleBoxEmpty \
					or outer_margin.get_theme_constant(&"margin_top") != 12 \
					or outer_margin.get_theme_constant(&"margin_bottom") != 16:
				failures.append("generic inspector chrome was not restored after family close")
			panel._detail_shell.visible = true
			panel._inspector_root.visible = true
			panel._object_detail_dialog.visible = true
			panel._sync_split_layout()
			await process_frame
	panel._detail_shell.visible = false
	panel._sync_split_layout()
	panel.custom_minimum_size.x = 460.0
	panel.offset_left = -460.0
	await process_frame
	if panel._inspector_root.size_flags_horizontal != Control.SIZE_EXPAND_FILL \
			or panel._inspector_root.size.x < 400.0:
		failures.append("closed dossier did not fill the 460px panel: flags=%d size=%s" % [
			panel._inspector_root.size_flags_horizontal, panel._inspector_root.size])


func _check_family_split(failures: PackedStringArray, panel: InspectorPanel,
		expected_detail: float) -> void:
	var dialog := panel._object_detail_dialog.get_node("Center/Dialog") as Control
	var detail_rect := panel._detail_shell.get_global_rect()
	var dossier_rect := panel._inspector_root.get_global_rect()
	var overlap := detail_rect.intersection(dossier_rect)
	if overlap.size.x > 1.0 and overlap.size.y > 1.0:
		failures.append("family detail occludes the dossier column: overlap=%s detail=%s dossier=%s" % [
			overlap, detail_rect, dossier_rect])
	if absf(panel._detail_shell.size.x - expected_detail) > 1.0 \
			or absf(panel._inspector_root.size.x - 424.0) > 1.0:
		failures.append("family detail changed split widths: detail=%s dossier=%s expected_detail=%.0f" % [
			panel._detail_shell.size, panel._inspector_root.size, expected_detail])
	if dialog.size.x > panel._detail_shell.size.x + 1.0 \
			or dialog.size.y + 1.0 < panel._object_detail_dialog.size.y:
		failures.append("embedded family dialog escaped its shell: dialog=%s root=%s shell=%s" % [
			dialog.size, panel._object_detail_dialog.size, panel._detail_shell.size])
	var body := panel._object_detail_dialog.get_node("Center/Dialog/Body") as Control
	var scroll := panel._object_detail_dialog.get_node("Center/Dialog/Body/Scroll") as ScrollContainer
	if body == null or scroll == null or scroll.size.y < 80.0 \
			or body.size.y + 1.0 < panel._object_detail_dialog.size.y:
		failures.append("family detail did not fill height for scrolling: body=%s scroll=%s root=%s" % [
			body.size if body != null else Vector2.ZERO,
			scroll.size if scroll != null else Vector2.ZERO,
			panel._object_detail_dialog.size])


func _family_detail_payload() -> Dictionary:
	var long_effect := "威望Ⅰ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低2%。威望Ⅴ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低10%。"
	return {
		"kind": "family",
		"name": "王氏",
		"subtitle": "苍梧郡 · 聚贤 · 家族档案",
		"icon": "family.house",
		"accent": UITokens.ACCENT,
		"row": {
			"population": "128",
			"notable_people": 3,
			"owned_buildings": "12",
			"cash_claim": "3.56万",
			"productive_asset_value": "1.25万",
			"net_worth": "4.81万",
			"founded_day": 12,
			"decline_reviews": 0,
			"prestige_level": 4,
			"prestige_score": "90.0%",
			"trait_rows": [{
				"name": "求雨世家",
				"value": "核心特性",
				"detail": long_effect,
			}],
			"behavior_rows": [{
				"name": "积极的理财",
				"value": "投资偏好 · 32.0%",
			}, {
				"name": "慷慨捐赠",
				"value": "需求偏好 · 18.0%",
			}],
			"effect_rows": [{
				"name": "地块 18 · 求雨",
				"value": long_effect,
				"detail": long_effect,
			}],
			"notable_person_rows": [{
				"name": "王某",
				"value": "产业所有者 · 纺织工坊",
			}],
		},
	}
