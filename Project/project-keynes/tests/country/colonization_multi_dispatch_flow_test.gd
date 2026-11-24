extends SceneTree

## 复现并锁定「连续派遣多支开拓队，只有第一支成功」（2026-11-21 玩家上报）。
##
## 走玩家真实可见的路径，不碰原生经济：派发面板 -> 确认 -> 宿主回填命令结果 ->
## 玩家在地图上点一个新的目的地 -> 再确认。每一步只断言玩家能看到/点到的东西。
##
## 根因是 `ColonizationPlannerPanel.handle_map_cell` 在面板不处于「可派遣」页时
## 直接 return false：派遣成功后面板自动切到「派遣进展」，此后地图左键被
## game_ui_manager 整口吞掉，玩家点新目的地毫无反应，第二支队伍永远派不出去。

var _failures := 0


class DispatchStub extends RefCounted:
	var quote_calls := 0
	var expeditions: Array = []          # [{handle,target,source,family,population,state}]
	var busy := false
	var revision := 0
	var next_handle := 900

	func dispatch_cell_display_name(cell: int) -> String:
		return {3: "长安", 8: "洛阳", 22: "临海新城", 24: "北方谷地",
			26: "西陲谷地"}.get(cell, "目的地")

	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		var handles := PackedInt64Array()
		var families := PackedInt64Array()
		var sources := PackedInt32Array()
		var targets := PackedInt32Array()
		var populations := PackedInt64Array()
		var states := PackedInt32Array()
		var due_days := PackedInt64Array()
		var departures := PackedInt64Array()
		var costs := PackedInt32Array()
		for row in expeditions:
			handles.append(int(row["handle"]))
			families.append(int(row["family"]))
			sources.append(int(row["source"]))
			targets.append(int(row["target"]))
			populations.append(int(row["population"]))
			states.append(int(row["state"]))
			due_days.append(100)
			departures.append(90)
			costs.append(4)
		return {"ok": true, "total": expeditions.size(), "busy": busy,
			"expedition_handles": handles, "family_handles": families,
			"source_cells": sources, "target_cells": targets,
			"populations": populations, "states": states, "due_days": due_days,
			"departure_days": departures, "route_costs": costs}

	func get_family_expedition_snapshot(handle: int) -> Dictionary:
		for row in expeditions:
			if int(row["handle"]) == handle:
				return {"ok": true, "expedition_handle": handle,
					"target_cell": int(row["target"]),
					"source_cell": int(row["source"]), "state": int(row["state"]),
					"population": int(row["population"]),
					"route_cells": PackedInt32Array([int(row["source"]),
						int(row["target"])]),
					"route_count": 2, "due_day": 100}
		return {"ok": false, "code": "colonization_expedition_invalid"}

	func get_family_dispatch_candidates(source: int, offset: int, limit: int) -> Dictionary:
		var handles := PackedInt64Array([11, 12])
		var people := PackedInt64Array([6, 5])
		var names := PackedStringArray(["长安王氏", "长安李四"])
		var prestige := PackedInt32Array([1, 0])
		var owned := PackedInt64Array([2, 1])
		var claims := PackedInt64Array([1000000, 500000])
		return {"ok": true, "cell_idx": source, "total": 2, "has_more": false,
			"family_handles": handles, "populations": people,
			"family_names": names, "prestige_levels": prestige,
			"owned_buildings": owned, "cash_claims": claims}

	func get_family_dispatch_preview(handle: int, source: int) -> Dictionary:
		return {"ok": true, "behavior_rows": [{"name": "采集营地"}],
			"branch": {"populations": 6, "cash_claims": 1000000,
				"owned_buildings": 2, "prestige_levels": 1},
			"traits": {"display_names": PackedStringArray(["采集传统"]),
				"core": PackedByteArray([1]),
				"descriptions": PackedStringArray(["更倾向投资采集建筑。"]),
				"behavior_selector_display_names": PackedStringArray(["采集营地"])},
			"effects": {"effect_display_names": PackedStringArray(["产出加成"]),
				"effect_current_descriptions": PackedStringArray(["提高2%。"])}}

	func get_family_colonization_quotes(target: int, family: int, source: int,
			offset: int, limit: int) -> Dictionary:
		quote_calls += 1
		if target == 999 or target == source:
			return {"ok": false, "code": "colonization_target_invalid"}
		var handles := PackedInt64Array()
		var cells := PackedInt32Array()
		var maximums := PackedInt64Array()
		var tokens := PackedInt64Array()
		var source_names := PackedStringArray()
		var surnames := PackedStringArray()
		var all: Array = []
		var source_cells: Array = [source] if source >= 0 else [3, 8]
		for cell in source_cells:
			for family_handle in [11, 12]:
				if family > 0 and family != family_handle:
					continue
				all.append([family_handle, cell, (6 if cell == 3 else 20) - 1])
		for i in range(offset, mini(all.size(), offset + limit)):
			var row: Array = all[i]
			handles.append(row[0])
			cells.append(row[1])
			maximums.append(row[2])
			tokens.append(target * 100000 + row[1] * 1000 + row[0] + revision * 10000000)
			source_names.append(dispatch_cell_display_name(row[1]))
			surnames.append("王" if row[0] == 11 else "李")
		return {"ok": true, "kind": "colonize", "busy": busy,
			"total": all.size(), "has_more": false, "family_handles": handles,
			"source_cells": cells, "maximum_populations": maximums,
			"quote_tokens": tokens, "source_settlement_names": source_names,
			"surnames": surnames}

	func get_family_colonization_quote_detail(_token: int, _people: int) -> Dictionary:
		return {"ok": true, "travel_days": 4, "busy": busy,
			"kit_place_buildings": true,
			"kit_building_ids": PackedInt32Array([1]),
			"kit_building_counts": PackedInt64Array([1]),
			"kit_building_display_names": PackedStringArray(["采集营地"]),
			"kit_partial": false}


func _expect(label: String, passed: bool) -> void:
	print("  [%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1


func _make_panel(stub) -> Control:
	var panel := load("res://scenes/ui/colonization_planner_panel.tscn").instantiate() as Control
	panel.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(panel)
	panel.set_player_controller(stub)
	return panel


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_WINDOWED
		root.position = Vector2i(-32000, -32000)
	await _inline_start_case()
	await _queued_receipt_case()
	print("=== colonization multi dispatch flow: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


## 内联结算（经济空闲边界立刻生效）：派第一支 -> 面板切到「派遣进展」->
## 玩家点第二块空地 -> 必须换目的地并回到可派遣列表 -> 第二支能提交。
func _inline_start_case() -> void:
	var stub := DispatchStub.new()
	var panel := _make_panel(stub)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel.open_target(22)
	var entry_row: Button = panel._quote_row_refs.get("3:11")
	_expect("destination entry lists families for the clicked target",
		panel.visible and panel._target_cell == 22 and entry_row != null)
	# 还没点家族时不能派遣：这是面板既有的正确状态，不是本条缺陷。
	_expect("no family is pre-selected before the player picks one",
		panel._selected_quote.is_empty() and panel._start.disabled)
	var row: Button = entry_row
	_expect("the first family row is selectable", row != null)
	if row == null:
		panel.queue_free()
		return
	panel._on_reusable_quote_pressed(row)
	panel._population.value = 2
	panel._submit_selected()
	_expect("the first dispatch is submitted", sent.size() == 1
		and int(sent[0].get("target_cell", -1)) == 22)
	# 宿主真实回填：命令成功，开拓队 900 去 22。
	stub.expeditions.append({"handle": 900, "target": 22, "source": 3,
		"family": 11, "population": 2, "state": 1})
	panel.set_command_result({"ok": true, "code": "colonization_started",
		"expedition_handle": 900, "message": "Family expedition started"})
	print("[multi-flow/inline] tab_after_start=", panel._current_tab,
		" target=", panel._target_cell)
	_expect("after a start the panel shows the running expeditions",
		panel._current_tab == "expeditions")
	var consumed: bool = panel.handle_map_cell(24)
	print("[multi-flow/inline] map_click_24 consumed=", consumed,
		" target=", panel._target_cell, " tab=", panel._current_tab)
	_expect("a map click on a new destination retargets the planner",
		consumed and panel._target_cell == 24)
	_expect("after retargeting the planner is back on the dispatch list",
		panel._current_tab == "quotes")
	var second_row: Button = panel._quote_row_refs.get("3:11")
	_expect("the new target offers dispatchable families again",
		second_row != null and not panel._start.disabled)
	if second_row != null:
		panel._on_reusable_quote_pressed(second_row)
		panel._population.value = 2
		panel._submit_selected()
	_expect("the second dispatch towards another target is submitted",
		sent.size() == 2 and int(sent[1].get("target_cell", -1)) == 24)
	_expect("the second dispatch carries a quote for the new target, not a stale one",
		sent.size() == 2
		and int(sent[1].get("quote_token", 0)) / 100000 == 24)
	print("[multi-flow/inline] quote_calls=", stub.quote_calls,
		" second=", sent[1] if sent.size() > 1 else {})
	panel.queue_free()
	await process_frame


## 后台经济（命令先排队）：排队回执先到、当天结算回执再把它切成「派遣进展」。
## 这两步都发生在玩家还没点第二块地之前，必须仍然能改目的地。
func _queued_receipt_case() -> void:
	var stub := DispatchStub.new()
	var panel := _make_panel(stub)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel.open_target(22)
	var row: Button = panel._quote_row_refs.get("3:11")
	if row == null:
		_expect("queued fixture has a family row", false)
		panel.queue_free()
		return
	panel._on_reusable_quote_pressed(row)
	panel._population.value = 2
	panel._submit_selected()
	panel.set_command_result({"ok": true, "code": "colonization_queued",
		"message": "Family expedition queued until settlement"})
	_expect("a queued dispatch keeps the planner on the dispatch list",
		panel._current_tab == "quotes")
	# 次日结算：原生回执 STARTED 经 player_controller 回填到面板。
	stub.expeditions.append({"handle": 900, "target": 22, "source": 3,
		"family": 11, "population": 2, "state": 1})
	panel.set_command_result({"ok": true, "code": "STARTED",
		"message": "开拓队已经出发。"})
	_expect("the settlement receipt moves the planner to the running list",
		panel._current_tab == "expeditions")
	var consumed: bool = panel.handle_map_cell(24)
	print("[multi-flow/queued] map_click_24 consumed=", consumed,
		" target=", panel._target_cell, " tab=", panel._current_tab)
	_expect("a settlement receipt does not lock the map after the first party",
		consumed and panel._target_cell == 24 and panel._current_tab == "quotes")
	var second_row: Button = panel._quote_row_refs.get("3:11")
	_expect("the second target is dispatchable after the receipt",
		second_row != null and not panel._start.disabled)
	if second_row != null:
		panel._on_reusable_quote_pressed(second_row)
		panel._population.value = 2
		panel._submit_selected()
	_expect("a second party is submitted after the receipt arrives",
		sent.size() == 2 and int(sent[1].get("target_cell", -1)) == 24)
	print("[multi-flow/queued] sent=", sent)
	panel.queue_free()
	await process_frame
