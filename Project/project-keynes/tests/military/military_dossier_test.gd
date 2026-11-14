extends SceneTree

## 军务档案页的契约（headless）：
##   1) 部队页把 攻/防/速 画成平级三联，且不出现"完好/战备环"这类废可视化；
##   2) 战线页用对阵表把双方同指标并排（5 行），没有 KPI 带；
##   3) 同一身份重复 set_model 不增删节点；
##   4) 外国部队不给动作；
##   5) InspectorPanel 里存在 %MilitaryDossier，且 show/close 会驱动 DetailShell；
##   6) MilitaryViewModel.army_dossier / front_dossier 输出形状稳定。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_dossier_test.gd

const DOSSIER_SCENE := preload("res://scenes/ui/military_dossier.tscn")
const PANEL_SCENE := preload("res://scenes/ui/inspector_panel.tscn")
const VM_SCRIPT := preload("res://scripts/ui/military_view_model.gd")

var _failures := PackedStringArray()
var _dossier
var _panel


class FakeFacade:
	func army(handle: int) -> Dictionary:
		return {
			"ok": true, "handle": handle, "owner_slot": 0, "cell": 10,
			"headcount": 100, "attack_q16": 65536, "defense_q16": 32768,
			"speed_q16": 98304, "organization_q16": 40000, "morale_q16": 30000,
			"supply_ratio_q16": 50000, "ration_ratio_q16": 60000,
			"pay_ratio_q16": 70000, "stance": 1, "mission": 1, "target_cell": 12,
			"area_id": -1, "engagement": -1, "move_points_q16": 0,
			"reinforce_enabled": true, "funds": 0, "name_seed": 3, "moved_day": 5,
			"prev_cell": 9, "personnel": 100, "ration_stock": 10,
			"composition": [
				{"unit": 0, "count": 60, "quality_q8": 256, "condition_q16": 50000},
				{"unit": 1, "count": 40, "quality_q8": 512, "condition_q16": 60000},
			],
			"supply_days": PackedInt64Array([20, 10, 8, 0, 5, 30]),
			"convoys": [], "path": PackedInt32Array([11, 12]),
		}

	func catalog() -> Dictionary:
		return {}

	func catalog_view() -> Dictionary:
		return {"ok": true, "units": [], "categories": []}

	func country_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "country_slot": 0, "wars": []}

	func armies(_handle: int) -> Array:
		return []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_army_page()
	await _test_front_page()
	await _test_panel_integration()
	await _test_view_model_shapes()
	_expect(_dossier != null and _dossier.identity() == "", "clear() drops the dossier identity")
	if _dossier != null:
		_dossier.queue_free()
	if _panel != null:
		_panel.queue_free()
	await process_frame
	_finish()


func _spawn_dossier() -> void:
	_dossier = DOSSIER_SCENE.instantiate()
	get_root().add_child(_dossier)
	await process_frame


func _army_payload(handle: int, enabled: bool) -> Dictionary:
	return {
		"ok": true, "kind": "army", "identity": "army:%d" % handle,
		"kicker": "部队档案", "title": "第 7 军", "subtitle": "青川 · 本国 · 推进",
		"icon": &"military.unit.line", "accent": Color(0.5, 0.3, 0.2),
		"focus_cell": 10, "selected": handle,
		"kpis": [
			{"id": "heads", "title": "兵力", "value": 100.0, "kind": "count",
				"caption": "1 类兵种"},
			{"id": "morale", "title": "士气", "value": 0.45, "kind": "percent", "caption": ""},
			{"id": "supply", "title": "补给", "value": 0.5, "kind": "percent",
				"caption": "口粮 60%"},
			{"id": "pay", "title": "军饷", "value": 0.7, "kind": "percent", "caption": ""},
		],
		"army": {
			"peer_stats": [
				{"label": "攻击", "text": "12.4", "color": Color(0.12, 0.075, 0.04)},
				{"label": "防御", "text": "8.1", "color": Color(0.12, 0.075, 0.04)},
				{"label": "速度", "text": "1.5", "color": Color(0.12, 0.075, 0.04)},
			],
			"composition": {"title": "编成", "total": "100 人", "segments": [
				{"label": "步兵", "text": "100", "value": 1.0, "color": Color(0.5, 0.4, 0.2)}]},
			"composition_rows": [{
				"id": "0_1",
				"cells": {
					"unit": {"text": "长矛兵", "icon": "military.unit.line"},
					"heads": {"text": "60", "sort": 60.0},
					"quality": {"text": "Q1"},
				},
			}],
			"supply_rows": [{"id": 0, "label": "口粮", "value": 0.66, "text": "20 日",
				"marker": 0.23, "color": Color(0.24, 0.46, 0.4)}],
			"badges": [{"text": "补给低", "accent": Color(0.55, 0.19, 0.13)}],
			"note": "行军 · 剩 2 格",
			"actions": [
				{"id": "locate", "label": "定位", "enabled": true},
				{"id": "move", "label": "移动", "enabled": enabled},
				{"id": "area", "label": "军事控制", "enabled": enabled},
			],
			"same_cell_rows": [{
				"id": 202,
				"cells": {
					"name": {"text": "第 8 军", "icon": "military.banner", "sub": "青川"},
					"heads": {"text": "40", "sort": 40.0},
					"owner": {"text": "本国"},
				},
			}],
		},
	}


func _front_payload() -> Dictionary:
	return {
		"ok": true, "kind": "front", "identity": "front:1234",
		"kicker": "战线档案", "title": "青川·北境", "subtitle": "本国 ↔ 邻国",
		"icon": &"military.war.front", "accent": Color(0.5, 0.3, 0.2),
		"focus_cell": 42, "selected": 1234,
		"front": {
			"versus": {
				"rows": [
					{"label": "兵力", "own_value": 1000.0, "enemy_value": 600.0,
						"own_text": "1000", "enemy_text": "600"},
					{"label": "攻击", "own_value": 12.4, "enemy_value": 8.1,
						"own_text": "12.4", "enemy_text": "8.1"},
					{"label": "防御", "own_value": 8.1, "enemy_value": 9.4,
						"own_text": "8.1", "enemy_text": "9.4"},
					{"label": "士气", "own_value": 0.6, "enemy_value": 0.4,
						"own_text": "60%", "enemy_text": "40%"},
					{"label": "补给", "own_value": 0.55, "enemy_value": 0.62,
						"own_text": "55%", "enemy_text": "62%"},
				],
				"own_color": Color(0.24, 0.46, 0.4),
				"enemy_color": Color(0.55, 0.19, 0.13),
				"own_label": "我方", "enemy_label": "敌方",
			},
			"footnote": "推进 62% · 交战 3 段 · 接触 9 边",
			"army_rows": [{
				"id": 7,
				"cells": {
					"name": {"text": "第 7 军"},
					"heads": {"text": "1000", "sort": 1000.0},
					"attack": {"text": "12.4"},
					"owner": {"text": "本国"},
				},
			}],
			"army_visible": true,
			"engagement_rows": [{
				"id": 5500000,
				"cells": {
					"zone": {"text": "青川·北境"},
					"progress": {"text": "50%", "value": 0.5},
					"attacker": {"text": "本国"},
				},
			}],
			"engagement_visible": true,
		},
	}


func _test_army_page() -> void:
	await _spawn_dossier()
	var first := _army_payload(7, true)
	_dossier.set_model(first)
	await process_frame
	_expect(_dossier.kind() == "army", "army payload switches the page to the army group")
	_expect(_dossier.get_node("%ArmyGroup").visible, "army group is visible")
	_expect(not _dossier.get_node("%FrontGroup").visible, "front group is hidden")
	_expect(not _dossier.get_node("%Versus").visible, "the versus table stays hidden on army")
	_expect(_dossier.get_node("%PeerStats").visible, "peer stats are visible on army")
	_expect(_dossier.get_node("%PeerStats").stat_count() == 3,
		"attack / defense / speed are three peer stats")
	var peers: Array = _dossier.get_node("%PeerStats")._stats
	_expect(String((peers[0] as Dictionary).get("label", "")) == "攻击",
		"the first peer stat is attack")
	_expect(String((peers[1] as Dictionary).get("label", "")) == "防御",
		"the second peer stat is defense")
	_expect(String((peers[2] as Dictionary).get("label", "")) == "速度",
		"the third peer stat is speed")
	_expect(_dossier.get_node("%KpiRow").visible, "the state KPI row is visible on army")
	_expect(_dossier.get_node("%CompositionBar").segment_count() == 1,
		"composition bar receives its segments")
	_expect(_dossier.get_node("%SupplyBars").row_count() == 1,
		"supply bars receive their rows")
	_expect(_dossier.get_node("%Badges").get_child_count() == 1,
		"badge row shows the single warning")
	_expect(_dossier.get_node("%SameCellBlock").visible,
		"same-cell block is visible when another army shares the cell")
	_expect(not _dossier.get_node("%MoveButton").disabled,
		"own army enables the move action")
	_expect(_dossier.get_node("%Note").text == "行军 · 剩 2 格", "march note is applied")
	var nodes_before := _count_nodes(_dossier)
	var updated := _army_payload(7, false)
	updated["kpis"][0]["value"] = 42.0
	updated["army"]["note"] = "待命"
	_dossier.set_model(updated)
	await process_frame
	_expect(_count_nodes(_dossier) == nodes_before,
		"a same-identity refresh does not add or remove nodes (%d -> %d)"
			% [nodes_before, _count_nodes(_dossier)])
	_expect(_dossier.get_node("%Note").text == "待命", "refresh writes the new note")
	_expect(_dossier.get_node("%MoveButton").disabled,
		"a foreign army disables the move action")
	_expect(_dossier.get_node("%AreaButton").disabled,
		"a foreign army disables the area action")


func _test_front_page() -> void:
	_dossier.set_model(_front_payload())
	await process_frame
	_expect(_dossier.kind() == "front", "front payload switches the page to the front group")
	_expect(_dossier.get_node("%FrontGroup").visible, "front group is visible")
	_expect(not _dossier.get_node("%ArmyGroup").visible, "army group is hidden")
	_expect(_dossier.get_node("%Versus").visible, "the versus table replaces the army blocks")
	_expect(_dossier.get_node("%Versus").row_count() == 5,
		"the versus table compares five symmetric metrics")
	_expect(not _dossier.get_node("%PeerStats").visible,
		"peer stats belong to the army page only")
	_expect(not _dossier.get_node("%KpiRow").visible,
		"the front page has no KPI band (the versus table is the numbers)")
	_expect(_dossier.get_node("%EngagementBlock").visible,
		"the engagement block appears when the sector has engagements")
	_expect(_dossier.get_node("%FrontArmiesBlock").visible,
		"the front page lists the armies holding the sector")
	_expect(_dossier.get_node("%FrontArmiesTable").row_count() == 1,
		"the present-armies ledger receives its rows")
	_expect(_dossier.get_node("%EngagementTable").row_count() == 1,
		"the engagement ledger receives its rows")
	_expect(_dossier.get_node("%FrontFootnote").text.contains("推进"),
		"the footnote carries the advance / engagement summary")
	var quiet := _front_payload()
	quiet["front"]["engagement_rows"] = []
	quiet["front"]["engagement_visible"] = false
	_dossier.set_model(quiet)
	await process_frame
	_expect(not _dossier.get_node("%EngagementBlock").visible,
		"a quiet sector hides the engagement block")
	_dossier.clear()


func _test_panel_integration() -> void:
	_panel = PANEL_SCENE.instantiate()
	get_root().add_child(_panel)
	await process_frame
	# InspectorPanel 依赖一大片 UI/经济脚本。别的改动把依赖弄坏时，
	# 这里必须报失败，而不是让整段测试悄悄跳过（假绿）。
	if not _panel.has_method("show_military_dossier"):
		_expect(false, "InspectorPanel 没有编译出 show_military_dossier（依赖脚本报错？）")
		return
	var dossier = _panel.get_node_or_null("%MilitaryDossier")
	_expect(dossier != null, "InspectorPanel 场景里挂着 MilitaryDossier 页")
	_expect(not _panel.detail_open(), "the detail shell starts closed")
	_panel.show_military_dossier(_army_payload(7, true))
	await process_frame
	_expect(_panel.military_dossier_open(), "show_military_dossier 打开军务页")
	_expect(_panel.detail_open(), "opening the dossier opens the detail shell")
	_expect(_panel.military_dossier_identity() == "army:7", "the panel reports the open identity")
	_panel.refresh_military_dossier(_army_payload(7, true))
	_expect(_panel.military_dossier_open(), "refresh keeps the page open")
	_panel.close_detail(false)
	await process_frame
	_expect(not _panel.military_dossier_open(), "close_detail hides the military page")
	_expect(not _panel.detail_open(), "close_detail closes the detail shell")


func _test_view_model_shapes() -> void:
	var script: Script = VM_SCRIPT
	if not script.can_instantiate():
		_expect(false, "military_view_model.gd 未能编译（项目内有脚本报错？）")
		return
	var vm = VM_SCRIPT.new()
	var facade := FakeFacade.new()
	vm.configure({
		"military": {
			"available": true,
			"facade": facade,
			"snapshot": {"ok": true, "country_slot": 0},
			"armies": [],
			"catalog": {"units": []},
		},
		"country_handle": 1,
		"current_day": 9,
		"good_ids": PackedStringArray(),
	})
	_expect(vm.available(), "the military view model accepts the dossier context")
	var army: Dictionary = vm.army_dossier(7)
	_expect(bool(army.get("ok", false)), "army_dossier answers for a live army")
	_expect(String(army.get("identity", "")) == "army:7", "army identity is stable")
	_expect((army.get("kpis", []) as Array).size() == 4, "the army page has four state KPIs")
	var peer_stats: Array = (army.get("army", {}) as Dictionary).get("peer_stats", [])
	_expect(peer_stats.size() == 3, "the army page carries three peer stats")
	_expect(String((peer_stats[2] as Dictionary).get("label", "")) == "速度",
		"speed is reported as a peer stat")
	_expect(not (army.get("army", {}) as Dictionary).has("rings"),
		"the army page carries no decorative ring gauges")
	_expect(vm.army_dossier(0).is_empty() == false
		and not bool(vm.army_dossier(0).get("ok", true)),
		"an unknown army handle is reported, not faked")
	var sector := {
		"ok": true, "edge_key": 1234,
		"edges": [],
		"cells": PackedInt32Array([42, 43]),
		"edge_count": 2, "active_count": 1, "advance": 0.5,
		"engagements": [{"cell_a": 42, "cell_b": 43, "progress": 0.5,
			"attacker": 0, "battle": true}],
		"sides": [{"slot": 0, "heads": 100, "armies": 1,
			"handles": PackedInt64Array([7])}],
		"owners": PackedInt32Array([0, 1]),
		"player_slot": 0, "focus_cell": 42, "max_edges": 96,
	}
	var front: Dictionary = vm.front_dossier(sector)
	_expect(bool(front.get("ok", false)), "front_dossier answers for a live sector")
	_expect(String(front.get("identity", "")) == "front:1234", "front identity is stable")
	var front_data: Dictionary = front.get("front", {})
	var versus: Dictionary = front_data.get("versus", {})
	_expect((versus.get("rows", []) as Array).size() == 5,
		"the versus model carries five symmetric rows")
	var labels: Array = []
	for row in versus.get("rows", []):
		labels.append(String((row as Dictionary).get("label", "")))
	_expect(labels == ["兵力", "攻击", "防御", "士气", "补给"],
		"versus rows are ordered by player question: %s" % str(labels))
	_expect(versus.has("own_color") and versus.has("enemy_color"),
		"the versus model carries both side colours")
	_expect(not front_data.has("engagement_visible") == false,
		"the front model reports engagement visibility")
	_expect(vm.front_dossier({}).is_empty(), "an empty sector builds nothing")


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("=== military dossier test: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
