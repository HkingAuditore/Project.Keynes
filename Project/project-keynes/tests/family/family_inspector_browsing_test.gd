extends "res://tests/family/family_workspace_ui_test.gd"


class TestUI extends GameUIManager:
	func _ready() -> void:
		pass


class FamilyViewModel extends CellInspectorViewModel:
	var models: Dictionary = {}
	var pending := false

	func build_family_detail(_cell: HexCell, request: Dictionary) -> Dictionary:
		if pending:
			return {"data_pending": true}
		return models.get(String(request.get("row_id", "")), {}).duplicate(true)


func _run() -> void:
	var failures := PackedStringArray()
	root.size = Vector2i(1280, 720)
	var stage := Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	root.add_child(stage)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene).instantiate() as InspectorPanel
	stage.add_child(panel)
	panel.show()
	var ui := TestUI.new()
	root.add_child(ui)
	ui._right_panel = panel
	var cell := HexCell.new(0, 0)
	cell.index = 0
	ui._selected_cell = cell
	var vm := FamilyViewModel.new()
	for handle in [17, 22]:
		var family := _sample_model()
		family.actions.family_handle = handle
		family.row_id = "family_%d" % handle
		family.header.name = "白桥堡曾氏" if handle == 17 else "长河郡王氏"
		vm.models[family.row_id] = family
	ui._inspector_view_model = vm
	panel.object_details_requested.connect(ui._on_object_details_requested)
	panel.detail_visibility_changed.connect(ui._on_inspector_detail_visibility_changed)
	var rows: Array = []
	for handle in range(17, 37):
		rows.append({"id": "family_%d" % handle, "family_handle": handle,
			"name": "曾氏" if handle == 17 else "王氏宗族%d" % handle,
			"population": "128", "owned_buildings": "12", "cash_claim": "3.56万",
			"prestige": "IV"})
	var model := {"cell_index": 0, "header": {"title": "白桥堡", "subtitle": "本国城市 · 地块档案"},
		"tabs": [{"id": "geography", "label": "地理"}, {"id": "families", "label": "家族"}],
		"categories": {"geography": {"insights": [{"text": "平原"}]},
			"families": {"family_rows": rows}}}
	panel.set_model_for_selection(model)
	panel.select_tab("families")
	ui._layout_right_panel()
	await _settle()
	var list := panel._family_list as FamilyList
	var first := (list._row_refs.family_17 as Dictionary).button as Button
	first.pressed.emit()
	await _settle()
	var workspace := panel._family_workspace
	if not panel._inspector_root.visible or not panel.family_workspace_open():
		failures.append("opening family detail hid the tile directory")
	if workspace.current_page() != "overview":
		failures.append("first family open did not start at overview")
	var previous_focus := first.find_prev_valid_focus()
	if previous_focus == null or not workspace.is_ancestor_of(previous_focus):
		failures.append("keyboard focus cannot cross between the two columns")
	for viewport_size in [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080),
			Vector2i(1600, 960), Vector2i(1024, 720), Vector2i(1280, 720)]:
		root.size = viewport_size
		ui._layout_right_panel()
		await _settle()
		var left := panel._detail_shell.get_global_rect()
		var right := panel._inspector_root.get_global_rect()
		if not panel._inspector_root.is_visible_in_tree() or left.end.x > right.position.x + 1.0 \
				or absf(right.size.x - 424.0) > 1.0 \
				or not Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(panel.get_global_rect()):
			failures.append("resize %s lost bounded adjacent columns: %s / %s" % [viewport_size, left, right])
		if workspace.compact_navigation() != (workspace.size.x < FamilyWorkspace.COMPACT_WIDTH):
			failures.append("family navigation did not follow its actual width")
		_check_page_horizontal_bounds(workspace, failures)
	workspace.select_page("preferences", false)
	await _settle()
	var left_scroll := workspace.get_node("%PageScroll") as ScrollContainer
	left_scroll.scroll_vertical = 100000
	await _settle()
	var cards := workspace._find_cards(workspace._page_cache.preferences)
	if not cards.is_empty() and (cards.back() as Control).get_global_rect().end.y \
			> left_scroll.get_global_rect().end.y - 12.0:
		failures.append("the final family card cannot clear the decorative bottom frame")
	left_scroll.scroll_vertical = 80
	panel._scroll.scroll_vertical = 120
	await _settle()
	var right_scroll := panel._scroll.scroll_vertical
	var second := (list._row_refs.family_22 as Dictionary).button as Button
	second.pressed.emit()
	await _settle()
	if workspace.current_page() != "preferences" or left_scroll.scroll_vertical != 0 \
			or panel._scroll.scroll_vertical != right_scroll or not second.button_pressed:
		failures.append("switching family did not preserve chapter, directory scroll and selection")
	left_scroll.scroll_vertical = 80
	await _settle()
	var page_scroll := left_scroll.scroll_vertical
	var node_count := workspace.content_node_count()
	var page_id: int = (workspace._page_cache.preferences as Control).get_instance_id()
	second.pressed.emit()
	await _settle()
	if left_scroll.scroll_vertical != page_scroll \
			or (workspace._page_cache.preferences as Control).get_instance_id() != page_id:
		failures.append("clicking the current family reset or rebuilt its page")
	# 鼠标按下期间连续日更，再松开，验证目录按钮和详情节点均保持有效。
	panel._scroll.ensure_control_visible(second)
	await _settle()
	var point := second.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.position = point
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	root.push_input(down, true)
	var visibility_changes := [0]
	second.visibility_changed.connect(func() -> void: visibility_changes[0] += 1)
	var requests := [0]
	panel.object_details_requested.connect(func(_request: Dictionary) -> void: requests[0] += 1)
	for day in 50:
		panel.apply_live_patch({"tab_id": "families", "category": {"family_rows": rows}})
		var patch: Dictionary = vm.models.family_22.duplicate(true)
		patch.header.prestige_progress_text = "%d%%" % day
		panel.refresh_family_workspace(patch)
		await process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	root.push_input(up, true)
	await _settle()
	if requests[0] != 1 or visibility_changes[0] != 0 or not second.button_pressed \
			or workspace.content_node_count() != node_count \
			or (workspace._page_cache.preferences as Control).get_instance_id() != page_id \
			or left_scroll.scroll_vertical != page_scroll:
		failures.append("50 daily patches interrupted a click, selection, page or scroll")
	vm.pending = true
	ui._refresh_object_detail(true)
	if not panel.family_workspace_open() or workspace.content_node_count() != node_count:
		failures.append("a pending family snapshot erased committed detail")
	vm.pending = false
	if not ui.dismiss_overlay_menu():
		failures.append("Escape route did not dismiss the family detail")
	await create_timer(FamilyWorkspace.CLOSE_SECONDS + 0.08).timeout
	if panel.detail_open() or not panel.visible or root.gui_get_focus_owner() != second:
		failures.append("closing family detail did not retain the tile panel and restore row focus")
	second.pressed.emit()
	await _settle()
	if workspace.current_page() != "overview":
		failures.append("reopening a closed family detail did not reset to overview")
	vm.models.family_22.pages.people = []
	ui._refresh_object_detail(true)
	workspace.select_page("people", false)
	await _settle()
	var empty_page := workspace._page_cache.people as Control
	if empty_page.get_child_count() == 0:
		failures.append("an empty family chapter has no explanatory content")
	first.pressed.emit()
	await _settle()
	if workspace.current_page() != "people":
		failures.append("switching family reset a sparse chapter")
	vm.models.erase("family_17")
	ui._refresh_object_detail(true)
	if panel.detail_open() or not ui._object_detail_context.is_empty():
		failures.append("an invalid family snapshot retained stale detail")
	vm.models.family_17 = _sample_model()
	first.pressed.emit()
	await _settle()
	panel.select_tab("geography")
	await create_timer(FamilyWorkspace.CLOSE_SECONDS + 0.08).timeout
	if panel.detail_open():
		failures.append("leaving the family tab retained family detail")
	panel.select_tab("families")
	(panel._family_list._row_refs.family_17.button as Button).pressed.emit()
	await _settle()
	model.cell_index = 1
	panel.set_model_for_selection(model)
	await _settle()
	if panel.detail_open() or not ui._object_detail_context.is_empty():
		failures.append("changing tile retained stale family context")
	(panel._family_list._row_refs.family_17.button as Button).pressed.emit()
	await _settle()
	var closes := [0]
	panel.close_requested.connect(func() -> void: closes[0] += 1)
	(panel.get_node("%CloseButton") as Button).pressed.emit()
	if closes[0] != 1 or panel.detail_open():
		failures.append("tile close button did not close both dossiers")
	stage.queue_free()
	ui.queue_free()
	await process_frame
	if failures.is_empty():
		print("[family-inspector-browsing] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[family-inspector-browsing] FAIL: %s" % failure)
		quit(1)


func _settle() -> void:
	for frame in 5:
		await process_frame
