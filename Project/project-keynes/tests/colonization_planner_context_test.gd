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
		var cell := 3 if source == 3 or (source < 0 and offset == 0) else 8
		var maximum := 5 if cell == 3 else 12
		return {"ok": true, "kind": kind, "target_cell": target,
			"total": 2 if source < 0 else 1, "has_more": source < 0 and offset == 0,
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


var _failures := 0


func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
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
	quit(0 if _failures == 0 else 1)


func _run_city_dispatch() -> void:
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i.ZERO
	var stub := DispatchControllerStub.new()
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(stub)
	panel.open_target(22)
	_expect("all quote pages contribute cities before any family is displayed",
		panel._source_city.item_count == 3 and not panel._has_quote_rows()
		and panel._start.disabled and stub.calls == [[-1, 0], [-1, 1]])
	_expect("named city choices and migration intent are visible",
		panel._source_city.get_item_text(1) == "长安"
		and panel._source_city.get_item_text(2) == "洛阳"
		and panel._title.text == "迁徙")
	panel._source_city.select(1)
	panel._on_source_city_selected(1)
	var row: Button = panel._quote_row_refs.get(11)
	row.pressed.emit()
	_expect("smaller non-home branch can be selected with its own population cap",
		panel._selected_quote.source_cell == 3 and int(panel._population.value) == 5
		and not panel._start.disabled and stub.calls.back()[0] == 3)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel._submit_selected()
	_expect("submitted intent retains the chosen city, family, token and population",
		sent.size() == 1 and sent[0].source_cell == 3 and sent[0].family_handle == 11
		and sent[0].quote_token == 71 and sent[0].population == 5)
	panel._source_city.select(2)
	panel._on_source_city_selected(2)
	_expect("switching cities clears selection and disables dispatch until a new family is picked",
		panel._selected_quote.is_empty() and panel._start.disabled
		and panel._source_filter == 8 and stub.calls.back()[0] == 8)
	row = panel._quote_row_refs.get(11)
	row.pressed.emit()
	panel._submit_selected()
	_expect("same family in another city dispatches that city's branch",
		sent.size() == 2 and sent[1].source_cell == 8 and sent[1].quote_token == 72
		and sent[1].population == 12)
	var row_id := row.get_instance_id()
	panel.refresh_visible()
	_expect("daily refresh keeps the selected city and stable family controls",
		panel._source_filter == 8 and panel._quote_row_refs[11].get_instance_id() == row_id
		and panel._selected_quote.source_cell == 8)
	panel._source_city.select(1)
	panel._on_source_city_selected(1)
	row = panel._quote_row_refs.get(11)
	row.pressed.emit()
	stub.empty_source = true
	panel.refresh_visible()
	_expect("a depleted branch clears stale dispatch and leaves the city selector usable",
		panel._selected_quote.is_empty() and panel._start.disabled
		and not panel._source_city.disabled)
	panel.open_target(22, 11, 8)
	_expect("a family branch context preserves its explicit source city",
		panel._source_filter == 8 and panel._source_city.get_selected_id() == 8
		and panel._has_quote_rows())
	row = panel._quote_row_refs.get(11)
	row.pressed.emit()
	for viewport_size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.size = viewport_size
		await create_timer(0.25).timeout
		await process_frame
		await process_frame
		var rect: Rect2 = panel.get_global_rect()
		var start: Rect2 = panel._start.get_global_rect()
		print("dispatch layout: viewport=%s panel=%s confirm=%s minimum=%s" % [root.get_visible_rect(), rect, start, panel.get_combined_minimum_size()])
		_expect("left dispatch panel and confirm button fit at %s" % viewport_size,
			rect.position.x == 16.0 and rect.position.y >= 64.0
			and rect.end.x < viewport_size.x * 0.5 and rect.end.y <= viewport_size.y
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
