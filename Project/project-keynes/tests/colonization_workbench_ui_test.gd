extends SceneTree

class DispatchStub extends RefCounted:
	var count := 8
	var quote_calls := 0
	var preview_calls := 0
	var busy := false
	var expired := false
	var revision := 0
	var removed := false
	var modern_unlocked := false

	func dispatch_cell_display_name(cell: int) -> String:
		return {3: "长安", 8: "洛阳", 22: "临海新城", 24: "北方谷地"}.get(cell, "目的地")

	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 0, "busy": busy}

	func get_family_dispatch_candidates(source: int, offset: int, limit: int) -> Dictionary:
		var handles := PackedInt64Array()
		var people := PackedInt64Array()
		var names := PackedStringArray()
		var prestige := PackedInt32Array()
		var owned := PackedInt64Array()
		var claims := PackedInt64Array()
		for i in range(offset, mini(count, offset + limit)):
			if removed and i == 0:
				continue
			handles.append(11 + i)
			people.append(6 + i if source == 3 else 20 + i)
			names.append("%s%s氏" % [dispatch_cell_display_name(source), "王" if i == 0 else "李%02d" % i])
			prestige.append(i % 6)
			owned.append(1 + i % 4)
			claims.append(1000000 * (i + 1))
		return {"ok": true, "cell_idx": source, "total": count,
			"has_more": offset + limit < count, "family_handles": handles,
			"populations": people, "family_names": names, "prestige_levels": prestige,
			"owned_buildings": owned, "cash_claims": claims}

	func get_family_dispatch_preview(handle: int, source: int) -> Dictionary:
		preview_calls += 1
		var i := handle - 11
		var behavior_rows: Array = [{"name": "采集营地"}, {"name": "早期商栈"}]
		if modern_unlocked:
			behavior_rows.append({"name": "自动化农场"})
		return {"ok": true, "behavior_rows": behavior_rows,
			"branch": {"populations": 6 + i if source == 3 else 20 + i,
			"cash_claims": 1000000 * (i + 1), "owned_buildings": 1 + i % 4, "prestige_levels": i % 6},
			"traits": {"display_names": PackedStringArray(["采集传统", "勤劳持家"]),
				"core": PackedByteArray([1, 1]),
				"descriptions": PackedStringArray(["更倾向投资采集建筑，并优先选择相关职业。", "更倾向积累生活储备。"]),
				"behavior_selector_display_names": PackedStringArray(["采集营地", "早期商栈", "自动化农场"])},
			"effects": {"effect_display_names": PackedStringArray(["本城总体产出加成"]),
				"effect_current_descriptions": PackedStringArray(["当地当前威望档：本城总体产出提高2%。"])} }

	func get_family_colonization_quotes(target: int, family: int, source: int,
			offset: int, limit: int) -> Dictionary:
		quote_calls += 1
		if target == 999 or target == source:
			return {"ok": false, "code": "colonization_target_invalid"}
		if target == 55:
			return {"ok": true, "total": 0}
		var handles := PackedInt64Array()
		var cells := PackedInt32Array()
		var maximums := PackedInt64Array()
		var tokens := PackedInt64Array()
		var source_names := PackedStringArray()
		var surnames := PackedStringArray()
		var all: Array = []
		for cell in ([3, 8] if source < 0 else [source]):
			for i in range(count):
				if (family > 0 and family != 11 + i) or (removed and i == 0):
					continue
				all.append([11 + i, cell, (6 + i if cell == 3 else 20 + i) - 1])
		for i in range(offset, mini(all.size(), offset + limit)):
			var row: Array = all[i]
			handles.append(row[0])
			cells.append(row[1])
			maximums.append(row[2])
			tokens.append(target * 100000 + row[1] * 1000 + row[0] + revision * 10000000)
			source_names.append(dispatch_cell_display_name(row[1]))
			surnames.append("王" if row[0] == 11 else "李")
		return {"ok": true, "kind": "relocate" if target == 22 else "colonize", "busy": busy,
			"total": all.size(), "has_more": offset + limit < all.size(), "family_handles": handles,
			"source_cells": cells, "maximum_populations": maximums, "quote_tokens": tokens,
			"source_settlement_names": source_names, "surnames": surnames}

	func get_family_colonization_quote_detail(_token: int, _people: int) -> Dictionary:
		if expired:
			return {"ok": false, "code": "colonization_quote_expired"}
		return {"ok": true, "travel_days": 4, "busy": busy, "kit_place_buildings": true,
			"kit_building_ids": PackedInt32Array([1]), "kit_building_counts": PackedInt64Array([1]),
			"kit_building_display_names": PackedStringArray(["采集营地"]), "kit_partial": false}

class InspectorStub extends InspectorPanel:
	func close_detail(_notify: bool = true) -> void:
		pass

class ManagerStub extends GameUIManager:
	func _ready() -> void:
		pass

class CountryStub extends RefCounted:
	func cell_summary(cell: int) -> Dictionary:
		return {"ok": true, "owned": true, "country_handle": 10 if cell == 3 else 20}

class EconomyStub extends RefCounted:
	var reads := 0
	var modern_unlocked := false
	var snapshot_unavailable := false
	func family_cell_snapshot(_cell: int, _offset: int, _limit: int) -> Dictionary:
		reads += 1
		return {"ok": true, "family_handles": PackedInt64Array([11]), "populations": PackedInt64Array([6])}
	func get_family_traits(_handle: int) -> Dictionary:
		return {"ok": true, "behavior_axes": PackedInt32Array([0, 0, 3, 3]),
			"behavior_selector_stable_ids": PackedStringArray([
				"gathering_ground", "automated_farm", "berries", "computer"]),
			"behavior_selector_display_names": PackedStringArray([
				"采集营地", "自动化农场", "浆果", "计算机"])}
	func building_cell_snapshot(_cell: int) -> Dictionary:
		if snapshot_unavailable:
			return {"ok": false, "pending": true}
		return {"ok": true,
			"building_type_ids": PackedStringArray(["gathering_ground", "automated_farm"]),
			"building_technology_available": PackedByteArray([1, 1 if modern_unlocked else 0])}
	func market_cell_snapshot(_cell: int) -> Dictionary:
		if snapshot_unavailable:
			return {"ok": false, "pending": true}
		return {"ok": true, "good_ids": PackedStringArray(["berries", "computer"]),
			"good_technology_available": PackedByteArray([1, 0])}
	func get_family_branch_effects(_handle: int, _cell: int) -> Dictionary:
		return {"ok": true}

class ControllerGuard extends PlayerController:
	var country := CountryStub.new()
	func _resolve_player_country() -> Dictionary:
		_player_country_handle = 10
		return {"ok": true, "facade": country}

var _failures := 0

func _init() -> void:
	_run.call_deferred()

func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1

func _make_panel(stub) -> ColonizationPlannerPanel:
	var panel := load("res://scenes/ui/colonization_planner_panel.tscn").instantiate() as ColonizationPlannerPanel
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(stub)
	return panel

func _run() -> void:
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_WINDOWED
		root.position = Vector2i(-32000, -32000)
	var stub := DispatchStub.new()
	var panel := _make_panel(stub)
	panel.open_source(3, 11)
	_expect("source first opens with a real branch and no fabricated quote",
		panel.visible and panel.is_target_picking() and panel._source_filter == 3
		and panel._selected_quote.family_handle == 11 and panel._selected_quote.quote_token == 0
		and stub.quote_calls == 0 and panel._start.disabled)
	_expect("source branch details are available before choosing a destination",
		panel._preview_traits.text.contains("采集传统") and panel._preview_metrics.text.contains("当地族人 6"))
	_expect("dispatch preference text and badges hide locked buildings",
		panel._preview_preferences.text.contains("采集营地")
		and not panel._preview_preferences.text.contains("自动化农场")
		and panel._pref_badges._labels.size() == 2
		and panel._pref_badges._labels[0].text == "采集营地")
	panel._population.value = 2
	_expect("invalid map targets preserve the chosen origin and family",
		not panel.try_target_cell(999) and not panel.try_target_cell(55)
		and panel.is_target_picking() and panel._selected_quote.family_handle == 11 and panel._target_cell == -1)
	_expect("valid target continues directly to dispatch with the chosen population",
		panel.try_target_cell(22) and not panel.is_target_picking() and not panel._start.disabled
		and panel._selected_quote.family_handle == 11 and panel._source_filter == 3
		and int(panel._population.value) == 2 and panel._title.text == "迁徙")
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	var before := panel._selected_quote.duplicate(true)
	var row: Button = panel._quote_row_refs.get(12)
	panel._on_row_preview_entered(row)
	await create_timer(0.2).timeout
	_expect("delayed hover previews another family without changing the dispatch",
		panel._preview_family == 12 and panel._selected_quote == before and int(panel._population.value) == 2)
	var reads := stub.preview_calls
	panel._on_row_preview_exited(row)
	_expect("leaving hover restores the pinned family and reuses its cache",
		panel._preview_family == 11 and stub.preview_calls == reads)
	panel._submit_selected()
	_expect("confirmation submits the pinned branch rather than the hover branch",
		sent.size() == 1 and sent[0].source_cell == 3 and sent[0].family_handle == 11
		and sent[0].target_cell == 22 and sent[0].population == 2)
	panel.begin_target_selection()
	panel.cancel_target_selection()
	_expect("canceling map selection leaves the ready dispatch intact", panel._target_cell == 22 and not panel._start.disabled)
	panel.begin_target_selection()
	_expect("changing the destination preserves the branch and people and updates the quote",
		panel.try_target_cell(24) and panel._title.text == "开拓"
		and panel._selected_quote.family_handle == 11 and int(panel._population.value) == 2
		and int(panel._selected_quote.quote_token) != int(before.quote_token))
	var row_id: int = panel._quote_row_refs[11].get_instance_id()
	panel._search.text = "李"
	panel._search.text_changed.emit("李")
	_expect("search hides summaries without changing the pinned dispatch",
		not panel._quote_row_refs[11].visible and panel._selected_quote.family_handle == 11)
	panel._search.clear()
	panel._search.text_changed.emit("")
	panel._sort.select(1)
	panel._display_order.clear()
	panel._apply_list_filter_sort()
	var order := panel._display_order.duplicate()
	stub.revision += 1
	panel.refresh_visible()
	_expect("daily quote refresh keeps the chosen branch, order and control instances",
		panel._selected_quote.family_handle == 11 and panel._quote_row_refs[11].get_instance_id() == row_id
		and panel._display_order == order and int(panel._population.value) == 2)
	stub.modern_unlocked = true
	panel.refresh_visible()
	_expect("technology unlock refreshes both preference presentations",
		panel._preview_preferences.text.contains("自动化农场")
		and panel._pref_badges._labels.size() == 3
		and panel._pref_badges._labels[2].text == "自动化农场")
	stub.expired = true
	panel._refresh_selected_kit()
	_expect("expired quote detail disables dispatch", panel._start.disabled)
	stub.expired = false
	stub.busy = true
	panel.refresh_visible()
	panel._refresh_selected_kit()
	_expect("settlement keeps a real quote queueable", not panel._start.disabled and panel._start.text.contains("排队"))
	stub.removed = true
	stub.busy = false
	panel.refresh_visible()
	_expect("disappearing local branch clears the selection and route", panel._selected_quote.is_empty() and panel._start.disabled)
	panel.queue_free()
	await process_frame
	await _run_density_and_layout()
	await _run_manager_entrypoints()
	_run_roster_entrypoint()
	_run_controller_guard()
	print("=== colonization workbench: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)

func _run_density_and_layout() -> void:
	for count in [8, 40, 100]:
		var stub := DispatchStub.new()
		stub.count = count
		var panel := _make_panel(stub)
		panel.open_target(22)
		_expect("target-first entry requires a city and family for %d branches" % count,
			panel._selected_quote.is_empty() and panel._start.disabled and stub.preview_calls == 0)
		panel._on_source_city_selected(panel._source_city.get_item_index(3))
		_expect("summaries do not eagerly fetch %d branch dossiers" % count,
			panel._quote_row_refs.size() == count and stub.preview_calls == 0)
		var first := panel._quote_row_refs.get(11) as Button
		first.pressed.emit()
		var scroll := panel.get_node("%RowsScroll") as ScrollContainer
		await process_frame
		await process_frame
		var visible_rows := floori((scroll.size.y + 2.0) / 50.0)
		_expect("1280x720 shows at least six compact summaries for %d branches" % count, visible_rows >= 6)
		for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
			root.size = resolution
			for scale in [1.0, 1.25]:
				root.content_scale_factor = scale
				await process_frame
				await process_frame
				panel._layout_left_panel()
				await create_timer(0.2).timeout
				var rect := panel.get_global_rect()
				var start := panel._start.get_global_rect()
				var viewport := root.get_visible_rect().size
				_expect("45 percent workbench and footer fit %s at %s for %d families" % [resolution, scale, count],
					absf(rect.size.x - roundf(viewport.x * 0.45)) < 1.0
					and rect.position.x == 16.0 and rect.end.y <= viewport.y - CountryActionBar.BAR_HEIGHT
					and rect.encloses(start))
				if count == 40 and OS.get_environment("PK_COLONIZATION_UI_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
					var output := "res://tmp/dispatch_workbench_qa"
					DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png("%s/workbench_%dx%d_%d.png" % [output, resolution.x, resolution.y, int(scale * 100)])
		panel.queue_free()
		await process_frame
		root.content_scale_factor = 1.0
		root.size = Vector2i(1280, 720)

func _run_manager_entrypoints() -> void:
	var panel := _make_panel(DispatchStub.new())
	var manager := ManagerStub.new()
	root.add_child(manager)
	var inspector := InspectorStub.new()
	var toolbar := MapOverlayToolbar.new()
	manager._right_panel = inspector
	manager._map_overlay_toolbar = toolbar
	manager._colonization_panel = panel
	panel.closed.connect(manager._on_dispatch_closed)
	manager._on_family_colonization_requested(11, 3)
	_expect("family entry opens the workbench and suppresses ordinary UI", panel.is_target_picking() and not inspector.visible and not toolbar.visible)
	_expect("camera safe area excludes the enlarged workbench", manager.map_safe_area().position.x > panel.get_global_rect().end.x)
	manager._cancel_colonization_targeting()
	_expect("canceling target mode keeps the workbench open", panel.visible and not panel.is_target_picking() and not inspector.visible)
	panel.close_panel()
	_expect("closing dispatch restores previous ordinary UI visibility", inspector.visible and toolbar.visible)
	manager._open_colonization_target(22)
	_expect("destination entry opens the same workbench without target picking", panel.visible and not panel.is_target_picking() and panel._target_cell == 22)
	var cell := HexCell.new()
	cell.index = 24
	panel.begin_target_selection()
	manager.show_cell_panel(cell)
	_expect("map selection updates the workbench rather than reopening the Inspector", panel._target_cell == 24 and not inspector.visible)
	panel.close_panel()
	manager.free()
	inspector.free()
	toolbar.free()
	panel.queue_free()
	await process_frame

func _run_roster_entrypoint() -> void:
	var list := load("res://scenes/ui/family_list.tscn").instantiate() as FamilyList
	var dispatched: Array = []
	var details: Array = []
	list.dispatch_requested.connect(func(family: int, source: int) -> void: dispatched.append([family, source]))
	list.details_requested.connect(func(request: Dictionary) -> void: details.append(request))
	list.set_rows([{"id": "family_11", "family_handle": 11, "source_cell": 3,
		"name": "长安王氏", "can_dispatch": true}])
	var button := list._row_refs["family_11"].dispatch as Button
	button.pressed.emit()
	_expect("city roster dispatch supplies the family and actual local source without opening details",
		dispatched == [[11, 3]] and details.is_empty())
	list.update_rows([{"id": "family_11", "family_handle": 11, "source_cell": 8,
		"name": "长安王氏", "can_dispatch": false}])
	_expect("roster update disables an unavailable source on the same action button", button.disabled)
	list.free()


func _run_controller_guard() -> void:
	var controller := ControllerGuard.new()
	var economy := EconomyStub.new()
	controller._economy_facade = economy
	_expect("dispatch readers reject foreign sources before accessing family state",
		not controller.get_family_dispatch_candidates(8).get("ok", false) and economy.reads == 0)
	var preview := controller.get_family_dispatch_preview(11, 3)
	_expect("local dispatch preview filters buildings and goods using source technology",
		preview.get("ok", false) and preview.behavior_rows.size() == 2
		and preview.behavior_rows[0].name == "采集营地"
		and preview.behavior_rows[1].name == "浆果"
		and preview.traits.behavior_selector_display_names.size() == 4)
	economy.modern_unlocked = true
	preview = controller.get_family_dispatch_preview(11, 3)
	_expect("completed building technology becomes visible without unlocking goods",
		preview.behavior_rows.size() == 3 and preview.behavior_rows[1].name == "自动化农场"
		and preview.behavior_rows[2].name == "浆果")
	economy.snapshot_unavailable = true
	preview = controller.get_family_dispatch_preview(11, 3)
	_expect("pending technology snapshots do not expose the unfiltered catalog",
		preview.get("ok", false) and preview.behavior_rows.is_empty())
	_expect("missing family and foreign source cannot be used as dispatch origins",
		not controller.can_family_colonize_from(99, 3) and not controller.can_family_colonize_from(11, 8))
	controller.free()
