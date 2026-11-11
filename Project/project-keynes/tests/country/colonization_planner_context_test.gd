extends SceneTree

class ControllerStub extends RefCounted:
	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 2, "has_more": false,
			"expedition_handles": PackedInt64Array([101, 102]),
			"family_handles": PackedInt64Array([11, 12]),
			"target_cells": PackedInt32Array([2, 3]),
			"states": PackedInt32Array([4, 1]),
			"populations": PackedInt64Array([3, 5])}

	func get_family_colonization_quotes(_target: int, _family: int,
			_source: int, _offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 0}


class DispatchControllerStub extends RefCounted:
	var calls: Array = []
	var empty_source := false
	var kind := "relocate"

	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 0}

	func get_family_colonization_quotes(target: int, _family: int,
			source: int, offset: int, _limit: int) -> Dictionary:
		calls.append([source, offset])
		if empty_source and source == 3:
			return {"ok": true, "kind": kind, "total": 0}
		var cell := 3 if source == 3 or (source < 0 and offset == 0 and not empty_source) else 8
		var maximum := 5 if cell == 3 else 12
		return {"ok": true, "kind": kind, "target_cell": target,
			"total": 2 if source < 0 and not empty_source else 1,
			"has_more": source < 0 and offset == 0 and not empty_source,
			"family_handles": PackedInt64Array([11]),
			"source_cells": PackedInt32Array([cell]),
			"source_settlement_names": PackedStringArray(["长安" if cell == 3 else "洛阳"]),
			"maximum_populations": PackedInt64Array([maximum]),
			"quote_tokens": PackedInt64Array([71 if cell == 3 else 72]),
			"surnames": PackedStringArray(["王"])}

	func get_family_colonization_quote_detail(_token: int, _population: int) -> Dictionary:
		return {"ok": true}

	func get_family_traits(_handle: int) -> Dictionary:
		return {"ok": true,
			"display_names": PackedStringArray(["采集传统", "勤劳持家"]),
			"core": PackedByteArray([1, 1]),
			"descriptions": PackedStringArray(["更倾向投资采集建筑。", "更倾向积累生活储备。"]),
			"behavior_selector_display_names": PackedStringArray(["采集营地", "早期商栈"]),
			"effect_display_names": PackedStringArray(["本城总体产出加成"])}


class PreparingControllerStub extends ControllerStub:
	var due_day := 7062
	var phase := 5
	var missing := 4

	func get_family_expeditions(offset: int, limit: int) -> Dictionary:
		var page := super.get_family_expeditions(offset, limit)
		page["due_days"] = PackedInt64Array([due_day, 7100])
		page["kit_missing_stock_identities"] = PackedInt64Array([19, 0])
		return page

	func get_family_expedition_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "kit_bridge_required_units": 100,
			"kit_bridge_missing_units": missing, "state": 4, "population": 3, "source_cell": 3, "target_cell": 2, "kit_material_required_units": 30,
			"kit_material_missing_units": 0, "kit_blocker": "BRIDGE",
			"kit_procurement_pending": true, "kit_procurement_phase": phase,
			"kit_procurement_started_day": 7061, "kit_procurement_good_id": 1}

	func good_display_name(_good: int) -> String:
		return "木材"


var _failures := 0


func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(ControllerStub.new())
	panel.open_target(2)
	var passed: bool = panel._current_tab == "expeditions" \
		and panel._expedition_row_refs.size() == 1 \
		and panel._expedition_row_refs.has(101)
	print("[%s] reopening a preparing target shows its own expedition" % ("PASS" if passed else "FAIL"))
	panel.open_target(2, 12)
	var family_scope: bool = panel._current_tab == "quotes"
	print("[%s] family context excludes other families' expeditions" % ("PASS" if family_scope else "FAIL"))
	panel.open_target(4)
	var empty_target: bool = panel._current_tab == "quotes"
	print("[%s] a new target opens dispatch quotes" % ("PASS" if empty_target else "FAIL"))
	panel.queue_free()
	await process_frame
	if not (passed and family_scope and empty_target):
		_failures += 1
	await _run_city_dispatch()
	await _run_preparing_refresh()
	await _run_topbar()
	quit(0 if _failures == 0 else 1)


func _run_preparing_refresh() -> void:
	var stub := PreparingControllerStub.new()
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(stub)
	panel.open_target(2)
	var row_wrap: HBoxContainer = panel._expedition_row_refs[101]
	var row := row_wrap.get_child(0) as Button
	_expect("opening preparation selects a party and exposes progress in details",
		panel._selected_expedition == 101 and panel._preview_meters.visible
		and panel._preview_meters.meter_count() == 3
		and panel._preview_effects.text.contains("正在用国库采购木材")
		and not panel._preview_effects.text.contains("阶段"))
	stub.due_day += 1
	stub.phase = 1
	stub.missing = 2
	panel._show_expeditions()
	_expect("daily preparation refresh keeps selection and updates detail progress",
		panel._selected_expedition == 101
		and panel._preview_meters._meters[1].value_text == "98%"
		and panel._preview_title.text != "在途队伍")
	_expect("preparation refresh preserves clickable row nodes",
		panel._expedition_row_refs[101] == row_wrap)
	var cancelled: Array = []
	panel.cancel_requested.connect(func(handle: int) -> void: cancelled.append(handle))
	panel._expedition_cancel.pressed.emit()
	_expect("detail action cancels the selected preparation", cancelled == [101]
		and panel._expedition_cancel.text == "取消筹备" and not panel._expedition_cancel.disabled)
	if OS.get_environment("PK_COLONIZATION_UI_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		var bar: PlayerTopBar = load("res://scenes/ui/player_top_bar.tscn").instantiate()
		root.add_child(bar)
		bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		bar.update_time_state(0, 1, 1, false, 10.0)
		bar.set_country_status(1000000.0, true, 100000, true)
		bar.set_era_name("石器时代")
		bar.set_dispatch_status(1, 2, 0)
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tmp/city_dispatch_qa/preparing.png")
		bar.queue_free()
	panel.queue_free()
	await process_frame


func _run_city_dispatch() -> void:
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i.ZERO
	var stub := DispatchControllerStub.new()
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(stub)
	panel.open_target(22)
	_expect("all quote pages immediately display branches grouped by source",
		panel._source_city.item_count == 3 and panel._quote_row_refs.size() == 2
		and panel._source_headers[3].text == "长安" and panel._source_headers[8].text == "洛阳"
		and panel._start.disabled and stub.calls == [[-1, 0], [-1, 1]])
	_expect("migration intent and both named origins are available",
		panel._title.text == "迁徙" and not panel._city_picker.visible)
	if OS.get_environment("PK_COLONIZATION_UI_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp/city_dispatch_qa"))
		root.get_texture().get_image().save_png("res://tmp/city_dispatch_qa/grouped_sources.png")
	var row: Button = panel._quote_row_refs["3:11"]
	row.pressed.emit()
	_expect("selecting the smaller branch fixes its source and local population cap",
		panel._selected_quote.source_cell == 3 and int(panel._population.value) == 5
		and not panel._start.disabled)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel._submit_selected()
	_expect("submitted intent retains city, family, token and population",
		sent.size() == 1 and sent[0].source_cell == 3 and sent[0].family_handle == 11
		and sent[0].quote_token == 71 and sent[0].population == 5)
	row = panel._quote_row_refs["8:11"]
	row.pressed.emit()
	panel._submit_selected()
	_expect("the same family in another city has a separate selectable row and token",
		sent.size() == 2 and sent[1].source_cell == 8 and sent[1].quote_token == 72
		and sent[1].population == 12 and not panel._quote_row_refs["3:11"].button_pressed)
	var row_id := row.get_instance_id()
	panel.refresh_visible()
	_expect("daily refresh preserves branch identity and controls across cities",
		panel._quote_row_refs["8:11"].get_instance_id() == row_id
		and panel._selected_quote.source_cell == 8)
	panel._quote_row_refs["3:11"].pressed.emit()
	stub.empty_source = true
	panel.refresh_visible()
	_expect("a depleted branch clears stale dispatch without removing other cities",
		panel._selected_quote.is_empty() and panel._start.disabled
		and panel._quote_row_refs.has("8:11") and not panel._quote_row_refs.has("3:11"))
	panel.open_target(22, 11, 8)
	_expect("a family branch context preserves its explicit source city",
		panel._source_filter == 8 and panel._source_city.get_selected_id() == 8
		and panel._has_quote_rows())
	row = panel._quote_row_refs.get("8:11")
	row.pressed.emit()
	for viewport_size in [Vector2i(1280, 720), Vector2i(2560, 1080), Vector2i(1024, 600)]:
		root.size = viewport_size
		await create_timer(0.25).timeout
		await process_frame
		await process_frame
		var rect: Rect2 = panel.get_global_rect()
		var start: Rect2 = panel._start.get_global_rect()
		print("dispatch layout: viewport=%s panel=%s confirm=%s minimum=%s" % [root.get_visible_rect(), rect, start, panel.get_combined_minimum_size()])
		_expect("left dispatch panel and confirm button fit at %s" % viewport_size,
			rect.position.x == 16.0 and rect.position.y >= 64.0
			and rect.end.x < root.get_visible_rect().size.x and rect.end.y <= root.get_visible_rect().size.y
			and rect.encloses(start))
		if OS.get_environment("PK_COLONIZATION_UI_CAPTURE") == "1" \
				and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var output := "res://tmp/city_dispatch_qa"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
			root.get_texture().get_image().save_png("%s/dispatch_%dx%d.png" % [
				output, viewport_size.x, viewport_size.y])
		panel._set_busy_status(true)
		await process_frame
		await process_frame
		_expect("settlement status also fits the left panel at %s" % viewport_size,
			panel.get_global_rect().end.y <= viewport_size.y - 16.0
			and panel.get_global_rect().encloses(panel._start.get_global_rect()))
		panel._set_busy_status(false)
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1.25
	await process_frame
	await process_frame
	panel._layout_left_panel()
	panel._set_busy_status(true)
	await process_frame
	await process_frame
	_expect("125 percent UI scale keeps the confirm button inside the map safe height",
		panel.get_global_rect().end.y <= root.get_visible_rect().size.y - 80.0
		and panel.get_global_rect().encloses(panel._start.get_global_rect()))
	panel.queue_free()
	await process_frame


func _run_topbar() -> void:
	var bar: PlayerTopBar = load("res://scenes/ui/player_top_bar.tscn").instantiate()
	root.add_child(bar)
	bar.update_time_state(0, 1, 1, false, 10.0)
	bar.set_country_status(1000000.0, true, 100000, true)
	bar.set_era_name("石器时代")
	var opened: Array = []
	bar.dispatch_requested.connect(func() -> void: opened.append(true))
	bar.set_dispatch_status(2, 1, 1)
	var button: Button = bar.get_node("%DispatchButton")
	await process_frame
	await process_frame
	print("dispatch top bar: viewport=%s bar=%s minimum=%s" % [root.get_visible_rect(), bar.get_global_rect(), bar.get_combined_minimum_size()])
	for control in bar.get_node("Margin/Row").get_children():
		if control is Control and control.visible:
			print("dispatch top item: %s %s minimum=%s" % [control.name, control.get_global_rect(), control.get_combined_minimum_size()])
	_expect("active dispatch entry stays inside the top bar", bar.size.y <= PlayerTopBar.BAR_HEIGHT
		and button.get_global_rect().end.x <= root.get_visible_rect().size.x
		and bar.get_global_rect().end.x <= root.get_visible_rect().size.x
		and button.size.y >= 44.0)
	_expect("top bar exposes active preparations and journeys", button.visible
		and button.text == ("派遣" if bar._compact_dispatch_hud else "派遣 4 队")
		and button.tooltip_text.contains("筹备中 2 队"))
	button.pressed.emit()
	_expect("top bar dispatch entry is keyboard accessible and actionable",
		opened.size() == 1 and button.focus_mode == Control.FOCUS_ALL)
	bar.set_dispatch_status(0, 0, 0)
	_expect("top bar removes the entry after all expeditions finish", not button.visible)
	bar.queue_free()
	await process_frame
