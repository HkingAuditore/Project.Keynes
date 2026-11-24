extends SceneTree

## 复现「连续派遣第二支开拓队派不出去」（2026-11-21 玩家上报）。
##
## 走玩家真实可见的路径，不碰原生经济：派发面板 -> 确认 -> 宿主回填命令结果 ->
## 玩家在地图上再点一个新的目的地 -> 再确认。每一步只断言玩家能看到/点到的东西。

var _failures := 0


class DispatchStub extends RefCounted:
	## Mimics the real controller/facade surface the panel talks to.
	var quote_calls := 0
	var expeditions: Array = []          # [{handle, target, source, family, population, state}]
	var busy := false
	var revision := 0

	func dispatch_cell_display_name(cell: int) -> String:
		var names := {3: "长安", 8: "洛阳", 22: "临海新城", 24: "北方谷地",
			26: "西陲谷地"}
		return String(names.get(cell, "目的地"))

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
					"source_cell": int(row["source"]),
					"state": int(row["state"]),
					"population": int(row["population"]),
					"route_cells": PackedInt32Array([int(row["source"]),
						int(row["target"])]),
					"route_count": 2, "due_day": 100}
		return {"ok": false, "code": "colonization_expedition_invalid"}

	func get_family_dispatch_candidates(source: int, _offset: int,
			_limit: int) -> Dictionary:
		return {"ok": true, "cell_idx": source, "total": 2, "has_more": false,
			"family_handles": PackedInt64Array([11, 12]),
			"populations": PackedInt64Array([6, 5]),
			"family_names": PackedStringArray(["长安王氏", "长安李四"]),
			"prestige_levels": PackedInt32Array([1, 0]),
			"owned_buildings": PackedInt64Array([2, 1]),
			"cash_claims": PackedInt64Array([1000000, 500000])}

	func get_family_dispatch_preview(_handle: int, _source: int) -> Dictionary:
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
			tokens.append(target * 100000 + row[1] * 1000 + row[0]
				+ revision * 10000000)
			source_names.append(dispatch_cell_display_name(row[1]))
			surnames.append("王" if row[0] == 11 else "李")
		return {"ok": true, "kind": "colonize", "busy": busy,
			"total": all.size(), "has_more": false,
			"family_handles": handles, "source_cells": cells,
			"maximum_populations": maximums, "quote_tokens": tokens,
			"source_settlement_names": source_names, "surnames": surnames}

	func get_family_colonization_quote_detail(_token: int,
			_people: int) -> Dictionary:
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
	var panel := load(
		"res://scenes/ui/colonization_planner_panel.tscn").instantiate() as Control
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
	await _inline_mode_case()
	await _worker_mode_case()
	await _roster_mode_case()
	print("=== colonization multi dispatch ui: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


## 内联（经济在空闲边界立刻结算）时的玩家流程：
## 派第一支 -> 面板自动切到「派遣进展」-> 玩家去地图上点第二块空地。
func _inline_mode_case() -> void:
	var stub := DispatchStub.new()
	var panel := _make_panel(stub)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel.open_target(22)
	_expect("the destination entry lists families for the clicked target",
		panel.visible and panel._target_cell == 22 and panel._has_quote_rows()
		and panel._current_tab == "quotes")
	var row: Button = panel._quote_row_refs.get("3:11")
	_expect("the first family row is selectable", row != null)
	_expect("no family is pre-selected before the player picks one",
		panel._selected_quote.is_empty() and panel._start.disabled)
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
	print("[multi-ui/inline] tab_after_start=", panel._current_tab,
		" target=", panel._target_cell)
	_expect("after a start the panel shows the running expeditions",
		panel._current_tab == "expeditions")
	# 玩家要点第二块空地：地图左键必须先到派发界面（game_ui_manager 的约定）。
	var consumed: bool = panel.handle_map_cell(24)
	print("[multi-ui/inline] map_click_24 consumed=", consumed,
		" target=", panel._target_cell, " tab=", panel._current_tab,
		" feedback=", panel._feedback.text)
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
	# 新目标的报价必须是新 token，不能拿第一支队伍的旧 token 去提交。
	_expect("the second dispatch carries a quote for the new target, not a stale one",
		sent.size() == 2
		and int(sent[1].get("quote_token", 0)) != int(sent[0].get("quote_token", 0))
		and int(sent[1].get("quote_token", 0)) > 0)
	print("[multi-ui/inline] quote_calls=", stub.quote_calls,
		" second=", sent[1] if sent.size() > 1 else {})
	panel.queue_free()
	await process_frame


## 后台经济（命令排队）时的玩家流程：命令返回 colonization_queued，
## 面板留在派遣列表上，玩家直接点第二块空地再派一次。
func _worker_mode_case() -> void:
	var stub := DispatchStub.new()
	var panel := _make_panel(stub)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel.open_target(22)
	var row: Button = panel._quote_row_refs.get("3:11")
	if row == null:
		_expect("worker mode fixture has a family row", false)
		panel.queue_free()
		return
	panel._on_reusable_quote_pressed(row)
	panel._population.value = 2
	panel._submit_selected()
	panel.set_command_result({"ok": true, "code": "colonization_queued",
		"message": "Family expedition queued until settlement"})
	_expect("a queued dispatch keeps the planner on the dispatch list",
		panel._current_tab == "quotes")
	# 命令真结算后主线程还会回填一次真实结果
	# （country_routes.gd 的 _on_player_command_settled -> set_command_result）。
	stub.expeditions.append({"handle": 902, "target": 22, "source": 3,
		"family": 11, "population": 2, "state": 1})
	panel.set_command_result({"ok": true, "code": "colonization_started",
		"expedition_handle": 902, "message": "Family expedition started"})
	_expect("the settled receipt moves the panel to the running list",
		panel._current_tab == "expeditions")
	var consumed: bool = panel.handle_map_cell(24)
	print("[multi-ui/worker] map_click_24 consumed=", consumed,
		" target=", panel._target_cell, " feedback=", panel._feedback.text)
	_expect("a queued dispatch still allows retargeting by map click",
		consumed and panel._target_cell == 24)
	var second_row: Button = panel._quote_row_refs.get("3:11")
	_expect("the second target is dispatchable after queueing",
		second_row != null and not panel._start.disabled)
	if second_row != null:
		panel._on_reusable_quote_pressed(second_row)
		panel._population.value = 2
		panel._submit_selected()
	_expect("a second queued dispatch is submitted",
		sent.size() == 2 and int(sent[1].get("target_cell", -1)) == 24)
	print("[multi-ui/worker] sent=", sent)
	panel.queue_free()
	await process_frame


## 顶栏「派遣」入口永远先落在全国在途列表上：那里也必须能点地图换目的地，
## 否则这个入口本身就派不出第二支队伍。
func _roster_mode_case() -> void:
	var stub := DispatchStub.new()
	stub.expeditions.append({"handle": 901, "target": 22, "source": 3,
		"family": 11, "population": 2, "state": 1})
	var panel := _make_panel(stub)
	var sent: Array = []
	panel.start_requested.connect(func(args: Dictionary) -> void: sent.append(args))
	panel.open_expeditions()
	_expect("the roster entry opens the nationwide running list",
		panel._current_tab == "expeditions" and panel._target_cell == -1)
	var consumed: bool = panel.handle_map_cell(26)
	print("[multi-ui/roster] map_click_26 consumed=", consumed,
		" target=", panel._target_cell, " tab=", panel._current_tab)
	_expect("a map click from the roster picks a destination",
		consumed and panel._target_cell == 26 and panel._current_tab == "quotes")
	_expect("the roster flow then asks for a source city",
		panel._source_filter < 0 and panel._start.disabled)
	panel._select_source_cell(3)
	var row: Button = panel._quote_row_refs.get("3:11")
	_expect("picking the source city lists its dispatchable families", row != null)
	if row != null:
		panel._on_reusable_quote_pressed(row)
		_expect("the roster flow reaches a ready dispatch",
			not panel._start.disabled and panel._target_cell == 26)
		panel._population.value = 2
		panel._submit_selected()
	_expect("a dispatch from the roster entry is submitted",
		sent.size() == 1 and int(sent[0].get("target_cell", -1)) == 26)
	panel.queue_free()
	await process_frame
