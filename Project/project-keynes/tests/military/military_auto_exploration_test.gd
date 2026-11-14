extends SceneTree

## 部队自动探路的跨层契约：
##   - PlayerController 的探路草稿不调用 preview_path，中心不可直达仍可确认；
##   - MilitaryDossier 的按钮、焦点链、E/Enter/Esc 和状态文案；
##   - MilitaryFacade 的 army.explore / trail / view 转发形状；
##   - WorldRuntimeHost 只把 trail 写进 explored，并把冻结快照逐日推给原生；
##   - whole-graph catch-up 的每个补跑日都先执行 exploration pre-day hook。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_auto_exploration_test.gd

const DOSSIER_SCENE := preload("res://scenes/ui/military_dossier.tscn")
const VIEW_MODEL_SCRIPT := preload("res://scripts/ui/military_view_model.gd")
const MILITARY_FACADE_SCRIPT := preload("res://scripts/military/military_facade.gd")

var _failures := PackedStringArray()
var _dossier


class PlayerFacade:
	var preview_calls := 0
	var detail := {
		"ok": true, "handle": 7, "owner_slot": 0, "cell": 100,
		"headcount": 100, "attack_q16": 65536, "defense_q16": 32768,
		"speed_q16": 98304, "organization_q16": 40000, "morale_q16": 30000,
		"supply_ratio_q16": 50000, "ration_ratio_q16": 60000,
		"pay_ratio_q16": 70000, "stance": 1, "mission": 0, "target_cell": -1,
		"area_id": -1, "engagement": -1, "move_points_q16": 0,
		"reinforce_enabled": true, "funds": 0, "name_seed": 3, "moved_day": 5,
		"prev_cell": 99, "personnel": 100, "ration_stock": 10,
		"composition": [], "supply_days": PackedInt64Array(),
		"convoys": [], "path": PackedInt32Array(),
	}

	func army(_handle: int) -> Dictionary:
		return detail.duplicate(true)

	func preview_path(_army: int, _cell: int) -> Dictionary:
		preview_calls += 1
		return {"ok": false, "reason": "military_path_unreachable"}

	func set_render_selection(_army: int) -> Dictionary:
		return {"ok": true}


class FakeRuntimeHost extends Node:
	var facade
	var map

	func get_military_facade():
		return facade

	func current_map():
		return map

	func map_wrap_period_x() -> float:
		return 0.0


class ExploreController extends PlayerController:
	var submitted: Array = []

	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		submitted.append({"id": id, "args": args.duplicate(true)})
		return {
			"ok": true, "code": "queued", "message": "探路命令已下达。",
		}


class ViewFacade:
	var detail: Dictionary = {}

	func army(_handle: int) -> Dictionary:
		return detail.duplicate(true)

	func catalog() -> Dictionary:
		return {}

	func catalog_view() -> Dictionary:
		return {"ok": true, "units": [], "categories": []}

	func country_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "country_slot": 0, "wars": []}

	func armies(_handle: int) -> Array:
		return []


class FakeWorldExt:
	var batches: Array = []
	var trail := PackedInt32Array([3, 4, 5])
	var observer_slot := -999
	var last_view := PackedByteArray()
	var last_day := -1
	var last_revision := -1
	var clear_count := 0
	var work := true

	func submit_military_commands(batch: Array) -> Dictionary:
		batches.append(batch.duplicate(true))
		return {"ok": true, "accepted": batch.size(), "rejected": []}

	func set_military_exploration_observer(slot: int) -> Dictionary:
		observer_slot = slot
		return {"ok": true, "observer_slot": slot}

	func set_military_exploration_view(slot: int, explored: PackedByteArray,
			day: int, revision: int) -> Dictionary:
		observer_slot = slot
		last_view = explored.duplicate()
		last_day = day
		last_revision = revision
		return {"ok": true, "cells": explored.size()}

	func get_military_vision_trail(slot: int) -> PackedInt32Array:
		return trail.duplicate() if slot == observer_slot or observer_slot == -999 \
			else PackedInt32Array()

	func clear_military_vision_trail(_slot: int) -> Dictionary:
		clear_count += 1
		trail.clear()
		return {"ok": true}

	func has_military_exploration_work() -> bool:
		return work


class TrailFacade:
	var trail := PackedInt32Array()
	var observer_slot := -1
	var last_view := PackedByteArray()
	var last_day := -1
	var last_revision := -1
	var view_pushes := 0
	var clear_count := 0
	var fail_clear := false
	var work := true

	func is_configured() -> bool:
		return true

	func has_military_exploration_work() -> bool:
		return work

	func set_military_exploration_observer(slot: int) -> Dictionary:
		observer_slot = slot
		return {"ok": true}

	func set_military_exploration_view(slot: int, explored: PackedByteArray,
			day: int, revision: int) -> Dictionary:
		observer_slot = slot
		last_view = explored.duplicate()
		last_day = day
		last_revision = revision
		view_pushes += 1
		return {"ok": true}

	func get_military_vision_trail(_slot: int) -> PackedInt32Array:
		return trail.duplicate()

	func clear_military_vision_trail(_slot: int) -> Dictionary:
		clear_count += 1
		if fail_clear:
			return {"ok": false, "reason": "forced_clear_failure"}
		trail.clear()
		return {"ok": true}


class ExploreMapGenerator extends MapGenerator:
	var facade

	func get_military_facade():
		return facade

	func get_military_daily_job():
		return null


class ExploreHostProbe extends WorldRuntimeHost:
	var poll_count := 0
	var refresh_count := 0

	func _poll_military_vision_revision() -> void:
		poll_count += 1

	func _refresh_vision() -> Dictionary:
		refresh_count += 1
		return {"ok": true}


class CatchupHostProbe extends WorldRuntimeHost:
	var prepared_days: Array[int] = []

	func _prepare_military_exploration_day(day: int) -> Dictionary:
		prepared_days.append(day)
		return {"ok": true, "day": day}


class CatchupFacade:
	func is_configured() -> bool:
		return true

	func should_run(_day: int) -> bool:
		return false

	func run_daily(_day: int) -> Dictionary:
		return {"ok": true}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_native_binding_shape()
	_test_military_facade_shape()
	_test_player_explore_order()
	await _test_dossier_explore_ui()
	_test_view_model_status_text()
	await _test_host_trail_boundary()
	_test_whole_graph_catchup_prepares_each_day()
	if _dossier != null:
		_dossier.queue_free()
	await process_frame
	_finish()


func _test_native_binding_shape() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect(false, "DCWorldExt is not loaded")
		return
	for method in ["set_military_exploration_observer",
			"set_military_exploration_view", "get_military_vision_trail",
			"clear_military_vision_trail", "has_military_exploration_work"]:
		_expect(ClassDB.class_has_method("DCWorldExt", method),
			"DCWorldExt exposes %s" % method)


func _test_military_facade_shape() -> void:
	var ext := FakeWorldExt.new()
	var facade = MILITARY_FACADE_SCRIPT.new()
	facade._configured = true
	facade._world_ext = ext
	var cells := PackedInt32Array([12, 13, 14])
	var result: Dictionary = facade.explore_army(77, 12, cells, 3)
	_expect(bool(result.get("ok", false)), "facade explore_army forwards the batch")
	_expect(ext.batches.size() == 1, "facade sends exactly one command row")
	if ext.batches.size() == 1:
		var row: Dictionary = (ext.batches[0] as Array)[0]
		_expect(String(row.get("op", "")) == "army.explore",
			"facade uses the army.explore op")
		_expect(int(row.get("army", 0)) == 77 and int(row.get("cell", -1)) == 12,
			"facade forwards army and anchor")
		_expect(row.get("cells", PackedInt32Array()) == cells,
			"facade forwards the selection unchanged")
		_expect(int(row.get("radius", 0)) == 3, "facade forwards the radius")
	_expect(facade.get_military_vision_trail(0) == PackedInt32Array([3, 4, 5]),
		"facade returns the native trail")
	_expect(bool(facade.clear_military_vision_trail(0).get("ok", false)),
		"facade clears the native trail")
	var pushed: Dictionary = facade.set_military_exploration_view(
		0, PackedByteArray([1, 0, 1]), 8, 19)
	_expect(bool(pushed.get("ok", false)) and ext.last_day == 8 \
		and ext.last_revision == 19, "facade forwards the frozen explored view")


func _test_player_explore_order() -> void:
	var map := _make_map(60, 60)
	var facade := PlayerFacade.new()
	var host := FakeRuntimeHost.new()
	host.facade = facade
	host.map = map
	var controller := ExploreController.new()
	get_root().add_child(controller)
	controller._runtime_host = host
	controller._player_country_handle = 4294967296  # generation 1, slot 0

	var started: Dictionary = controller.begin_military_arm_order(7, "explore", 6)
	_expect(bool(started.get("ok", false)), "explore order starts")
	_expect(String(controller.military_arm_order().get("mode", "")) == "explore",
		"the draft records explore mode")
	var clicked := controller.military_arm_order_click(100)
	_expect(clicked, "an explore map click consumes the map event")
	var draft: Dictionary = controller.military_arm_order()
	_expect(bool(draft.get("ready", false)), "explore is ready without a reachable centre")
	_expect(int(draft.get("days", -1)) == 0, "explore never fabricates an ETA")
	_expect(int(draft.get("cell_count", 0)) >= 1 \
		and int(draft.get("cell_count", 0)) <= 256,
		"explore selection is bounded to 256 cells")
	_expect(facade.preview_calls == 0,
		"explore draft never calls preview_path")
	var preview_cells: PackedInt32Array = controller._military_order_preview.get(
		"area", PackedInt32Array()).duplicate()
	var confirmed: Dictionary = controller.confirm_military_arm_order()
	_expect(bool(confirmed.get("ok", false)), "explore confirmation is accepted")
	_expect(controller.submitted.size() == 1, "confirmation emits one command")
	if controller.submitted.size() == 1:
		var sent: Dictionary = controller.submitted[0]
		var args: Dictionary = sent.get("args", {})
		_expect(StringName(sent.get("id", &"")) == &"military.army.explore",
			"confirmation uses military.army.explore")
		_expect(int(args.get("army", 0)) == 7 and int(args.get("cell", -1)) == 100,
			"confirmation sends army and anchor")
		_expect(args.get("cells", PackedInt32Array()) == preview_cells,
			"confirmation sends the highlighted selection")
		_expect(int(args.get("radius", 0)) == 6,
			"confirmation sends the chosen radius")
	_expect(controller.military_arm_order().is_empty() == false \
		and String(controller.military_arm_order().get("mode", "")).is_empty(),
		"successful confirmation closes the draft")

	controller.begin_military_arm_order(7, "explore", 1)
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	controller._dispatch_player_input(right_click)
	_expect(String(controller.military_arm_order().get("mode", "")).is_empty(),
		"right click cancels the explore draft")

	facade.detail["engagement"] = 0
	var rejected: Dictionary = controller.begin_military_arm_order(7, "explore", 1)
	_expect(not bool(rejected.get("ok", true)),
		"an engaged army cannot start an explore draft")
	controller.queue_free()


func _test_dossier_explore_ui() -> void:
	_dossier = DOSSIER_SCENE.instantiate()
	get_root().add_child(_dossier)
	await process_frame
	var events: Array = []
	_dossier.action_requested.connect(func(action: StringName, payload: Dictionary) -> void:
		events.append({"action": action, "payload": payload}))
	_dossier.set_model(_dossier_payload(true))
	await process_frame
	var explore: Button = _dossier.get_node("%ExploreButton")
	var locate: Button = _dossier.get_node("%LocateButton")
	var move: Button = _dossier.get_node("%MoveButton")
	var area: Button = _dossier.get_node("%AreaButton")
	var stop: Button = _dossier.get_node("%StopButton")
	_expect(explore.visible and not explore.disabled,
		"own army exposes an enabled explore command")
	_expect(explore.custom_minimum_size.y >= 44.0,
		"explore keeps a 44dp hit target")
	var chain: Array[Button] = [locate, move, area, explore, stop]
	for index in chain.size():
		var button := chain[index]
		var following := chain[(index + 1) % chain.size()]
		_expect(button.get_node(button.focus_neighbor_right) == following,
			"focus chain: %s -> %s" % [button.name, following.name])

	_dossier.set_order_state({
		"mode": "explore", "army": 7, "radius": 4, "ready": true,
		"cell_count": 37, "days": 0, "message": "",
	})
	await process_frame
	_expect(_dossier.get_node("%RadiusRow").visible, "explore shows its radius row")
	_expect(_dossier.get_node("%Label").text == "探查半径（格）",
		"explore labels the radius as exploration range")
	_expect(_dossier.get_node("%ConfirmOrder").text == "确认探查范围",
		"explore uses its own confirmation caption")
	var summary := String(_dossier.get_node("%OrderSummary").text)
	_expect(summary.contains("范围 37 格") and summary.contains("返回出发点") \
		and summary.contains("不会主动进入他国控制格"),
		"explore summary states scope, return and no-trespass contract")
	_expect(not summary.contains("预计") and not summary.contains("日"),
		"explore summary does not fabricate an ETA")

	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_E
	_expect(_dossier.handle_order_key(key), "E is consumed by the dossier")
	_expect(events.size() == 1 and StringName(events[0].action) == &"explore",
		"E requests the explore draft")
	key = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_ENTER
	_expect(_dossier.handle_order_key(key), "Enter is consumed while a draft is ready")
	_expect(events.size() == 2 and StringName(events[1].action) == &"confirm_order",
		"Enter confirms the explore draft")
	key = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_ESCAPE
	_expect(_dossier.handle_order_key(key), "Esc is consumed while a draft is open")
	_expect(events.size() == 3 and StringName(events[2].action) == &"cancel_order",
		"Esc cancels the explore draft")

	var nodes_before := _count_nodes(_dossier)
	var refreshed := _dossier_payload(true)
	refreshed["army"]["exploration"]["resolved"] = 19
	refreshed["army"]["mission_text"] = "探路 19/31"
	_dossier.set_model(refreshed)
	await process_frame
	_expect(_count_nodes(_dossier) == nodes_before,
		"same-identity exploration refresh does not rebuild nodes")
	_expect(_dossier.get_node("%Mission").text == "探路 19/31",
		"same-identity refresh updates the exploration text")

	_dossier.set_model(_dossier_payload(false))
	await process_frame
	_expect(not explore.visible, "foreign army hides the explore command")
	_expect(not stop.visible, "foreign army has no stop command")

	var engaged := _dossier_payload(true)
	engaged["army"]["actions"][3]["enabled"] = false
	engaged["army"]["actions"][3]["reason"] = "交战中无法开始探路。"
	_dossier.set_model(engaged)
	await process_frame
	_expect(explore.visible and explore.disabled,
		"engaged own army shows a disabled explore command")
	_expect(explore.tooltip_text == "交战中无法开始探路。",
		"disabled explore explains why it is unavailable")


func _test_view_model_status_text() -> void:
	var facade := ViewFacade.new()
	var vm = VIEW_MODEL_SCRIPT.new()
	vm.configure({
		"military": {
			"available": true, "facade": facade,
			"snapshot": {"ok": true, "country_slot": 0},
			"armies": [], "catalog": {"units": []},
		},
		"country_handle": 1, "current_day": 9,
		"good_ids": PackedStringArray(),
	})
	facade.detail = _view_detail({
		"phase": 0, "result": 0, "selected": 31, "resolved": 12, "blocked": 0,
	})
	_expect(_mission_text(vm) == "探路 12/31", "active exploration status")
	facade.detail = _view_detail({
		"phase": 1, "result": 1, "selected": 31, "resolved": 31, "blocked": 0,
	})
	_expect(_mission_text(vm) == "探路 31/31 · 返程中", "returning status")
	facade.detail = _view_detail({
		"phase": 2, "result": 0, "selected": 31, "resolved": 12, "blocked": 0,
	})
	_expect(_mission_text(vm) == "探路暂停 · 交战中", "battle pause status")
	facade.detail = _view_detail({
		"phase": 3, "result": 1, "selected": 31, "resolved": 31, "blocked": 0,
	})
	_expect(_mission_text(vm) == "探路完成 · 已返回", "completed status")
	facade.detail = _view_detail({
		"phase": 3, "result": 2, "selected": 31, "resolved": 28, "blocked": 3,
	})
	_expect(_mission_text(vm) == "探查结束 · 3 格无法探明 · 已返回",
		"blocked-but-returned status")
	facade.detail = _view_detail({
		"phase": 4, "result": 3, "selected": 31, "resolved": 31, "blocked": 0,
	})
	_expect(_mission_text(vm) == "探路完成 · 无法返回 · 原地待命",
		"no-return status")
	facade.detail = _view_detail({
		"phase": 3, "result": 4, "selected": 31, "resolved": 31, "blocked": 0,
	})
	_expect(_mission_text(vm) == "待命", "a cancelled row is not presented as a mission")
	facade.detail["engagement"] = 0
	var engaged_dossier: Dictionary = vm.army_dossier(7)
	var actions: Array = (engaged_dossier.get("army", {}) as Dictionary).get(
		"actions", [])
	var explore_action: Dictionary = {}
	for row in actions:
		if String((row as Dictionary).get("id", "")) == "explore":
			explore_action = row
			break
	_expect(not bool(explore_action.get("enabled", true)) \
		and String(explore_action.get("reason", "")).contains("交战"),
		"view model disables explore during an engagement with a reason")


func _test_host_trail_boundary() -> void:
	var map := _make_map(12, 9)
	var facade := TrailFacade.new()
	var host := ExploreHostProbe.new()
	var generator := ExploreMapGenerator.new()
	generator.facade = facade
	host._generator = generator
	host._current_map = map
	host._player_country_slot = 0
	host._country_visual_refresh_pending = false
	map.fog_solved = true
	var visible_before: PackedByteArray = map.visible_arr.duplicate()
	var fog_before: PackedByteArray = map.fog_k_arr.duplicate()
	facade.trail = PackedInt32Array([5, 6, 5])
	var prepared: Dictionary = host._prepare_military_exploration_day(12)
	_expect(bool(prepared.get("ok", false)), "host prepares an exploration day")
	_expect(int(prepared.get("trail_cells", 0)) == 3 \
		and int(prepared.get("new_explored", 0)) == 2,
		"host counts trail cells after dedupe")
	_expect(map.explored_arr[5] == 1 and map.explored_arr[6] == 1,
		"trail is merged into explored")
	_expect(map.visible_arr == visible_before and map.fog_k_arr == fog_before,
		"trail alone never writes visible or fog")
	_expect(facade.clear_count == 1 and facade.trail.is_empty(),
		"host clears the native trail only after merging")
	_expect(host.poll_count == 1 and host.refresh_count == 1,
		"host refreshes sources and runs the existing vision pass once")
	_expect(facade.view_pushes == 1 and facade.last_day == 12,
		"host pushes one frozen explored view for the day")
	_expect(facade.last_view == map.explored_arr,
		"the native view is a copy of the merged explored array")
	var pushes_before := facade.view_pushes
	var refresh_before := host.refresh_count
	var quiet: Dictionary = host._prepare_military_exploration_day(13)
	_expect(bool(quiet.get("ok", false)) and host.refresh_count == refresh_before,
		"no new explored cells and a solved map do not rerun vision")
	_expect(facade.view_pushes == pushes_before + 1 and facade.last_day == 13,
		"the frozen view still advances to the next day")
	facade.work = false
	var idle: Dictionary = host._prepare_military_exploration_day(14)
	_expect(bool(idle.get("skipped", false)) \
		and facade.view_pushes == pushes_before + 1,
		"no exploration work early-outs without copying or pushing the map")

	var failing_map := _make_map(6, 6)
	var failing := TrailFacade.new()
	failing.trail = PackedInt32Array([2])
	failing.fail_clear = true
	var failing_host := ExploreHostProbe.new()
	failing_host._current_map = failing_map
	failing_host._player_country_slot = 0
	var drained: Dictionary = failing_host._drain_military_exploration_trail(failing)
	_expect(not bool(drained.get("ok", true)) \
		and String(drained.get("reason", "")) == "forced_clear_failure",
		"a trail clear failure is reported to the save path")
	_expect(failing.trail == PackedInt32Array([2]),
		"a failed clear preserves the native trail for retry")
	host.queue_free()
	failing_host.queue_free()


func _test_whole_graph_catchup_prepares_each_day() -> void:
	var generator := ExploreMapGenerator.new()
	generator.facade = CatchupFacade.new()
	var host := CatchupHostProbe.new()
	host._generator = generator
	host._runtime_military_pending_target_day = 3
	host._runtime_military_last_commit_day = -1
	host._drain_runtime_military_commits()
	_expect(host.prepared_days == [0, 1, 2, 3],
		"whole-graph catch-up invokes the exploration hook once per replay day")
	_expect(host._runtime_military_pending_target_day == -1,
		"catch-up drains the pending military target")
	host.queue_free()


func _mission_text(vm) -> String:
	var payload: Dictionary = vm.army_dossier(7)
	return String((payload.get("army", {}) as Dictionary).get("mission_text", ""))


func _view_detail(exploration: Dictionary) -> Dictionary:
	return {
		"ok": true, "handle": 7, "owner_slot": 0, "cell": 100,
		"headcount": 100, "attack_q16": 65536, "defense_q16": 32768,
		"speed_q16": 98304, "organization_q16": 40000, "morale_q16": 30000,
		"supply_ratio_q16": 50000, "ration_ratio_q16": 60000,
		"pay_ratio_q16": 70000, "stance": 1, "mission": 3, "target_cell": -1,
		"area_id": -1, "engagement": -1, "move_points_q16": 0,
		"reinforce_enabled": true, "funds": 0, "name_seed": 3, "moved_day": 5,
		"prev_cell": 99, "personnel": 100, "ration_stock": 10,
		"composition": [], "supply_days": PackedInt64Array(),
		"convoys": [], "path": PackedInt32Array(),
		"exploration": exploration,
	}


func _dossier_payload(own: bool) -> Dictionary:
	var exploration := {
		"phase": 0, "result": 0, "selected": 31, "resolved": 12, "blocked": 0,
		"seen": 12, "visited": 0,
	}
	return {
		"ok": true, "kind": "army", "identity": "army:7",
		"kicker": "部队档案", "title": "第 7 军", "subtitle": "青川 · 本国 · 推进",
		"icon": &"military.unit.line", "accent": Color(0.5, 0.3, 0.2),
		"focus_cell": 100, "selected": 7,
		"kpis": [
			{"id": "heads", "title": "兵力", "value": 100.0, "kind": "count",
				"caption": "1 类兵种"},
			{"id": "morale", "title": "士气", "value": 0.45, "kind": "percent",
				"caption": ""},
			{"id": "supply", "title": "补给", "value": 0.5, "kind": "percent",
				"caption": "口粮 60%"},
			{"id": "pay", "title": "军饷", "value": 0.7, "kind": "percent",
				"caption": ""},
		],
		"army": {
			"own": own, "stance": 1, "mission_text": "探路 12/31",
			"peer_stats": [
				{"label": "攻击", "text": "12.4", "color": Color(0.12, 0.075, 0.04)},
				{"label": "防御", "text": "8.1", "color": Color(0.12, 0.075, 0.04)},
				{"label": "速度", "text": "1.5", "color": Color(0.12, 0.075, 0.04)},
			],
			"composition": {"title": "", "total": "100 人", "segments": [
				{"label": "步兵", "text": "100", "value": 1.0, "color": Color(0.5, 0.4, 0.2)}]},
			"composition_rows": [],
			"supply_rows": [],
			"badges": [],
			"note": "",
			"actions": [
				{"id": "locate", "label": "定位", "enabled": true},
				{"id": "move", "label": "行军", "enabled": own},
				{"id": "area", "label": "区域控制", "enabled": own},
				{"id": "explore", "label": "探路", "enabled": own},
				{"id": "stop", "label": "停止任务", "enabled": own},
			],
			"exploration": exploration,
			"same_cell_rows": [],
		},
	}


func _make_map(width: int, height: int) -> MapData:
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LandformType.LF.PLAIN
			cell.vegetation = VegetationType.VEG.NONE
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	var count := map.cell_count()
	map.country_slot_arr.resize(count)
	map.country_slot_arr.fill(-1)
	map.explored_arr.resize(count)
	map.explored_arr.fill(0)
	map.visible_arr.resize(count)
	map.visible_arr.fill(0)
	map.fog_k_arr.resize(count)
	map.fog_k_arr.fill(0)
	map.fog_solved = true
	return map


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] " + message)
		return
	_failures.append(message)
	push_error("[FAIL] " + message)


func _finish() -> void:
	print("=== military auto exploration: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
