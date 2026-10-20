extends "res://tests/ui/inspector_live_patch_test.gd"


class RetryViewModel extends CellInspectorViewModel:
	var waiting := true
	var ready_category: Dictionary = {}

	func _build_tab_category(_cell: HexCell, _tab: String) -> Dictionary:
		return _pending_category() if waiting else ready_category.duplicate(true)


class TestUI extends GameUIManager:
	func _ready() -> void:
		pass


func _run() -> void:
	var failures := PackedStringArray()
	root.size = Vector2i(1280, 720)
	var stage := Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	root.add_child(stage)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene).instantiate() as InspectorPanel
	stage.add_child(panel)
	var model := _make_model()
	model["cell_index"] = 0
	var geography: Dictionary = model.categories.geography
	geography["badges"] = [{"text": "小麦"}, {"text": "马匹"}]
	# 首次显示前写入模型，覆盖尚未完成 Container 排版的路径。
	panel.set_model_for_selection(model)
	panel.show()
	for i in 5:
		await process_frame
	for badge in panel._badge_row._labels:
		var expected := badge.get_theme_font("font").get_string_size(badge.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, badge.get_theme_font_size("font_size")).x
		if badge.custom_minimum_size.x < expected:
			failures.append("first-open badge was measured before inheriting its font")
	var badge_width := panel._badge_row._labels[0].custom_minimum_size.x
	panel.apply_live_patch({"tab_id": "geography", "category": geography})
	if not is_equal_approx(badge_width, panel._badge_row._labels[0].custom_minimum_size.x):
		failures.append("badge width changed on the first refresh")
	panel._scroll.ensure_control_visible(panel._badge_row)
	await _capture_if_requested("first_open")

	# 首次 pending -> 首份快照：必须创建此前不存在的名录和指标。
	model.categories.population = CellInspectorViewModel._pending_category()
	panel.set_model_for_selection(model)
	panel.select_tab("population")
	panel.apply_live_patch(_make_patch("population"))
	if panel._cohort_list == null:
		failures.append("first committed snapshot did not populate the pending tab")
		_finish_lifecycle(failures, stage)
		return
	var list = panel._cohort_list
	var list_id: int = list.get_instance_id()
	panel.apply_live_patch({"tab_id": "population",
		"category": CellInspectorViewModel._pending_category()})
	if panel._cohort_list != list or not list.visible:
		failures.append("transient pending cleared the displayed rows")
	var rows: Array = _population_category(0.0).cohort_rows
	rows[0]["wealth"] = "人均 1234567890.12"
	rows[0]["net"] = "+1234567890.12"
	panel.apply_live_patch({"tab_id": "population", "category": {"cohort_rows": rows}})
	# 回到稳定结构后，数值补丁不能重建名录。
	list = panel._cohort_list
	list_id = list.get_instance_id()
	for i in 5:
		await process_frame
	var refs: Dictionary = list._row_refs.cohort_1
	var button := refs.button as Button
	var header := button.get_node("Header") as Control
	if header.get_combined_minimum_size().x > button.size.x - 14.0 + 0.5:
		failures.append("large wealth/net values overflow the population row")
	var requests: Array = []
	panel.object_details_requested.connect(func(request: Dictionary) -> void: requests.append(request))
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = point
	down.pressed = true
	root.push_input(down, true)
	await process_frame
	var visibility_changes := [0]
	(refs.panel as Control).visibility_changed.connect(func() -> void: visibility_changes[0] += 1)
	for i in 50:
		panel.apply_live_patch({"tab_id": "population", "category": {"cohort_rows": rows}})
		await process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	root.push_input(up, true)
	await process_frame
	if visibility_changes[0] != 0 or requests.size() != 1 \
			or panel._cohort_list.get_instance_id() != list_id:
		failures.append("50 refreshes interrupted a held row click: visibility=%d requests=%d" % [
			visibility_changes[0], requests.size()])
	await _capture_if_requested("population")
	await _check_other_lists(failures, stage)
	await _check_async_retry(failures, panel, stage)
	_finish_lifecycle(failures, stage)


func _check_other_lists(failures: PackedStringArray, stage: Control) -> void:
	for spec in [["resource_list", _resource_category(0.0).resource_rows, "panel"],
			["building_list", _building_category(0.0).building_rows, "panel"],
			["family_list", [{"id": "family_1", "name": "王氏"}], "button"]]:
		var list = (load("res://scenes/ui/%s.tscn" % spec[0]) as PackedScene).instantiate()
		stage.add_child(list)
		list.set_rows(spec[1])
		var refs: Dictionary = list._row_refs.values()[0]
		var row := refs[spec[2]] as Control
		var changes := [0]
		row.visibility_changed.connect(func() -> void: changes[0] += 1)
		for i in 50:
			list.update_rows(spec[1])
		if changes[0] != 0:
			failures.append("%s toggled row visibility during value refresh" % spec[0])
		list.update_rows([])
		if row.visible:
			failures.append("%s did not hide a removed row" % spec[0])
		list.queue_free()
	await process_frame


func _check_async_retry(failures: PackedStringArray, panel: InspectorPanel, stage: Control) -> void:
	var vm := RetryViewModel.new()
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	cell.index = 0
	vm.set_context(map, null, null, null, 0.42, 22.0)
	vm.ready_category = _population_category(0.0)
	var ui := TestUI.new()
	stage.add_child(ui)
	ui._right_panel = panel
	ui._selected_cell = cell
	ui._inspector_view_model = vm
	panel.set_model_for_selection(_make_model().merged({"categories": {}}))
	panel.select_tab("market")
	panel.select_tab("population")
	ui._on_inspector_tab_data_requested("population")
	ui._on_object_details_requested({"kind": "cohort", "row_id": "cohort_1"})
	if ui._pending_object_request.is_empty():
		failures.append("pending detail request was discarded")
	vm.waiting = false
	await create_timer(0.4).timeout
	if panel._cohort_list == null or not panel.detail_open() \
			or not ui._pending_object_request.is_empty() or not ui._pending_inspector_tab.is_empty():
		failures.append("pending tab/detail did not resolve automatically")
	panel.close_detail(false)
	vm.waiting = true
	var cached := vm.build_tab_category(cell, "population")
	if not bool(cached.get("data_pending", false)) or not cached.has("cohort_rows"):
		failures.append("busy read lost the last committed category")
	ui._on_inspector_tab_data_requested("market")
	ui.hide_cell_panel()
	await create_timer(0.25).timeout
	if not ui._pending_inspector_tab.is_empty() or panel.detail_open():
		failures.append("stale retry survived closing the selected cell")
	map.visible_arr = PackedByteArray([0])
	map.explored_arr = PackedByteArray([1])
	if not vm.build_tab_category(cell, "population").is_empty():
		failures.append("cached category bypassed explored-only fog")
	map.explored_arr[0] = 0
	if not vm.build_object_detail(cell, {"kind": "cohort", "row_id": "cohort_1"}).is_empty():
		failures.append("cached detail bypassed unexplored fog")
	ui.queue_free()
	await process_frame


func _capture_if_requested(label: String) -> void:
	if not "--capture" in OS.get_cmdline_user_args():
		return
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var output := "res://tmp/inspector_lifecycle_%s.png" % label
	root.get_texture().get_image().save_png(output)
	print("[inspector-refresh-lifecycle] capture: %s" % ProjectSettings.globalize_path(output))


func _finish_lifecycle(failures: PackedStringArray, stage: Control) -> void:
	stage.queue_free()
	for failure in failures:
		push_error("[inspector-refresh-lifecycle] FAIL: %s" % failure)
	print("[inspector-refresh-lifecycle] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)
