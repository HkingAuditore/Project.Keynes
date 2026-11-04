extends SceneTree

## 外交章（DiplomacyWorkspace + DiplomacyViewModel）的 headless 契约测试。
##
## 用一份纯替身的会话模型（没有原生运行时）：领土镜像、探索/通视、国家快照、
## 军事快照都不读真世界，所以这里断言的是**接线与门控**，不是模拟数值。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/ui/diplomacy_workspace_test.gd

const Q16 := 65536
const DAY := 412
const PLAYER_SLOT := 0
const ENEMY_SLOT := 3
const NEIGHBOUR_SLOT := 4
const FAR_SLOT := 5
const HIDDEN_SLOT := 6
const PLAYER_HANDLE := 0x100000000
const ENEMY_HANDLE := 0x300000001
const NEIGHBOUR_HANDLE := 0x400000001
const FAR_HANDLE := 0x500000001
const HIDDEN_HANDLE := 0x600000001
const WAR_ID := 7
const SCENE := "res://scenes/ui/diplomacy_workspace.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"

## 5 行 × 8 列。row3 col6-7 是「已发现但隔着别人」的国家，row4 col4-7 是
## 「从未探索」的国家——两者是接壤/迷雾两种门控的正样本与反样本。
const OWNERS := [
	0, 0, 0, 0, 3, 3, 3, 3,
	0, 0, 0, 0, 3, 3, 3, 3,
	0, 0, 0, 0, 4, 4, 4, 4,
	0, 0, 0, 0, 4, 4, 5, 5,
	0, 0, 0, 0, 6, 6, 6, 6,
]
const CELLS := 40
const ROWS := 5
const WIDTH := 8

const NAMES := {0: "青川", 3: "赤原", 4: "河洛", 5: "沙州", 6: "幽都"}
const HANDLES := {0: PLAYER_HANDLE, 3: ENEMY_HANDLE, 4: NEIGHBOUR_HANDLE,
	5: FAR_HANDLE, 6: HIDDEN_HANDLE}

var _failures := PackedStringArray()


func _init() -> void:
	# 只有被当作主循环启动时（`-s`）才跑测试；截图 QA 会把本脚本当 fixture 容器
	# 实例化，那时主循环是别人的，不能在这里再起一套断言与 quit()。
	if not _runs_as_main_loop():
		return
	call_deferred("_run")


func _runs_as_main_loop() -> bool:
	var loop := Engine.get_main_loop()
	return loop == null or loop == self


## 给渲染验收用的公开入口：同一份 fixture，避免两组截图口径漂移。
func fixture_model(player_soldiers: int = 1200) -> Dictionary:
	return _fixture_model(player_soldiers)


func _run() -> void:
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 720)

	_check_view_model()
	await _check_workspace()
	await _check_commands()
	await _check_declare_blocked_by_soldiers()

	print("diplomacy workspace: %d failures" % _failures.size())
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	quit(0 if _failures.is_empty() else 1)


# ── 视图模型 ─────────────────────────────────────────────────────────────

func _check_view_model() -> void:
	var vm = DiplomacyViewModel.new()
	vm.configure(_fixture_model())
	_expect("view model reports itself available", bool(vm.available()))

	var roster: Array = vm.roster()
	_expect("roster lists every discovered foreign country", roster.size() == 3)
	var ids: Array = []
	var names: Array = []
	for row in roster:
		ids.append(int(row.id))
		names.append(String(row.name))
	_expect("roster is ordered war → adjacent → territory", ids == [
		ENEMY_HANDLE, NEIGHBOUR_HANDLE, FAR_HANDLE])
	_expect("roster names come from Country", names == ["赤原", "河洛", "沙州"])
	_expect("never-explored country stays out of the roster",
		not ids.has(HIDDEN_HANDLE))
	_expect("own country is not a foreign entry", not ids.has(PLAYER_HANDLE))

	var enemy := _row(roster, ENEMY_HANDLE)
	_expect("belligerent is tagged as a war with its id",
		String(enemy.relation.state) == "war" and int(enemy.relation.war_id) == WAR_ID)
	_expect("belligerent is at war and cannot be declared on again",
		not bool(enemy.can_declare)
		and String(enemy.declare_reason) == "正在交战")
	_expect("country under observation is tagged visible",
		String(enemy.contact) == "visible")
	var neighbour := _row(roster, NEIGHBOUR_HANDLE)
	_expect("adjacent peaceful country is declared as 接壤",
		bool(neighbour.adjacent) and int(neighbour.border_edges) > 0
		and String(neighbour.contact) == "explored")
	_expect("adjacent peaceful country can be declared on",
		bool(neighbour.can_declare) and String(neighbour.declare_reason).is_empty())
	var far := _row(roster, FAR_HANDLE)
	_expect("discovered but non-adjacent country is not marked 接壤",
		not bool(far.adjacent) and bool(far.can_declare))

	var overview: Dictionary = vm.overview_model()
	_expect("overview exposes four KPIs", (overview.kpis as Array).size() == 4)
	_expect("overview counts known countries",
		int(overview.kpis[0].value) == 3)
	_expect("overview counts the running war", int(overview.kpis[1].value) == 1)
	_expect("overview reads the player's own soldiers",
		int(overview.kpis[2].value) == 1200)
	_expect("overview counts occupied enemy cells",
		int(overview.kpis[3].value) == 2)
	_expect("power board ranks by territory",
		(overview.powers as Array).size() == 3
		and String(overview.powers[0].label) == "赤原")
	_expect("power board drops the baseline when the home country is the peak",
		float(overview.powers[0].marker) < 0.0)
	var small := _fixture_model()
	small["territory_count"] = 2
	var small_vm = DiplomacyViewModel.new()
	small_vm.configure(small)
	var small_powers: Array = small_vm.overview_model().powers
	_expect("power board draws the home baseline when someone is larger",
		absf(float(small_powers[0].marker) - 0.25) < 0.01)

	var wars: Array = vm.war_rows()
	_expect("war list has one running war", wars.size() == 1)
	_expect("war row names the enemy and its role",
		String(wars[0].enemy_name) == "赤原" and String(wars[0].role) == "进攻方")
	_expect("war row ages the war from its start day", int(wars[0].days) == DAY - 351)
	_expect("war row carries the four-part score sign-flipped for us",
		String(wars[0].score_text) == "+27")

	var sheet: Dictionary = vm.war_sheet(WAR_ID)
	_expect("war sheet resolves", bool(sheet.ok))
	_expect("war sheet carries a score row even without native parts",
		not (sheet.score_rows as Array).is_empty() and bool(sheet.score_estimated))
	_expect("war sheet lists the front", (sheet.fronts as Array).size() >= 1)
	_expect("war sheet focuses a cell to look at", int(sheet.focus_cell) >= 0)

	var country: Dictionary = vm.country_sheet(ENEMY_HANDLE)
	_expect("country sheet resolves", bool(country.ok))
	_expect("country sheet exposes six facts", (country.facts as Array).size() == 6)
	_expect("country sheet marks the cash fact as money",
		bool(_fact(country, "cash").get("money", false)))
	_expect("country sheet money text carries no currency unit",
		not _has_currency_unit(String(_fact(country, "cash").get("value", ""))))
	_expect("country sheet compares territory and soldiers",
		(country.compare as Array).size() == 2)
	_expect("country sheet offers peace instead of a declaration",
		String(country.relation.state) == "war" and int(country.peace_war_id) == WAR_ID
		and not bool((country.declare as Dictionary).get("enabled", true)))
	_expect("belligerent sheet says the war out loud",
		String(country.note).contains("正在交战"))

	var empty: Dictionary = vm.country_sheet(HIDDEN_HANDLE)
	_expect("a country outside the roster has no sheet", not bool(empty.ok))


# ── 工作区 ───────────────────────────────────────────────────────────────

func _check_workspace() -> void:
	var host := _theme_host()
	var workspace := (load(SCENE) as PackedScene).instantiate()
	host.add_child(workspace)
	await process_frame
	await process_frame
	workspace.set_player_controller(FakeController.new())
	workspace.set_model(_fixture_model())
	await process_frame

	_expect("workspace announces its three chapters",
		workspace.chapter_ids() == PackedStringArray(["overview", "countries", "wars"]))
	_expect("workspace opens on the overview",
		String(workspace.current_chapter()) == "overview")

	var roster_table := workspace.get_node("%RosterTable") as DossierLedgerTable
	workspace.select_chapter("countries")
	await process_frame
	_expect("country chapter fills the roster ledger",
		roster_table.row_count() == 3)
	_expect("roster ledger sorts by territory",
		int(roster_table.sorted_ids()[0]) == ENEMY_HANDLE)
	_expect("country chapter selects the first country",
		int(workspace.selected_country()) == ENEMY_HANDLE)
	var sheet_title := workspace.get_node("%SheetTitle") as Label
	_expect("country sheet shows the enemy name", sheet_title.text == "赤原")
	var facts := workspace.get_node("%SheetFacts") as InspectorFactGrid
	_expect("country sheet draws the fact grid", facts.fact_count() == 6)
	var peace_button := workspace.get_node("%PeaceButton") as Button
	var declare_button := workspace.get_node("%DeclareButton") as Button
	_expect("belligerent shows 议和 and hides 宣战",
		peace_button.visible and not declare_button.visible)

	# 选一个和平邻国：宣战按钮出现并可用。
	workspace.select_country(NEIGHBOUR_HANDLE)
	await process_frame
	_expect("peaceful country swaps in the 宣战 button",
		declare_button.visible and not peace_button.visible)
	_expect("peaceful country can be declared on",
		not declare_button.disabled and declare_button.tooltip_text.contains("宣战"))
	_expect("sheet title follows the selection", sheet_title.text == "河洛")

	# 同身份刷新不得重建节点树。
	var nodes_before := _count_nodes(workspace)
	workspace.refresh_model(_fixture_model())
	await process_frame
	await create_timer(0.30).timeout
	_expect("same-identity refresh keeps the node tree",
		_count_nodes(workspace) == nodes_before)
	_expect("same-identity refresh keeps the selection",
		int(workspace.selected_country()) == NEIGHBOUR_HANDLE)

	# 战事章：战争表、战争档案、议和按钮。
	workspace.select_chapter("wars")
	await process_frame
	var war_table := workspace.get_node("%WarTable") as DossierLedgerTable
	_expect("war chapter fills the war ledger", war_table.row_count() == 1)
	var war_title := workspace.get_node("%WarTitle") as Label
	_expect("war sheet title names the enemy", war_title.text == "对赤原")
	var war_peace := workspace.get_node("%WarPeaceButton") as Button
	_expect("war sheet offers 议和", war_peace.visible and not war_peace.disabled)
	_expect("war sheet renders a score row and a front",
		(workspace.get_node("%ScoreList") as DossierBarList).row_count() == 1
		and (workspace.get_node("%FrontList") as DossierBarList).row_count() >= 1)
	_expect("war sheet keeps the battle-log lines hidden with no event ring",
		not _any_log_row_visible(workspace))

	var pressed: Array = []
	workspace.peace_negotiation_requested.connect(
		func(war_id: int) -> void: pressed.append(war_id))
	war_peace.pressed.emit()
	_expect("议和 asks the shell for the peace window",
		pressed == [WAR_ID])
	# 窄屏下战争档案在折叠线以下，行上的议和必须是第二条通路。
	war_table.row_action.emit(WAR_ID, "peace")
	_expect("a war row opens the peace window without scrolling to the sheet",
		pressed == [WAR_ID, WAR_ID])

	# 定位：国家档案与战线两处都要把格交出去。
	var located: Array = []
	workspace.locate_cell_requested.connect(
		func(cell: int) -> void: located.append(cell))
	workspace.select_chapter("countries")
	await process_frame
	(workspace.get_node("%LocateButton") as Button).pressed.emit()
	_expect("定位 hands the selected country's cell to the map",
		located.size() == 1 and int(located[0]) == _first_cell(NEIGHBOUR_SLOT))

	# 主题材质：卡片必须是军务一脉的纸框，而不是灰盒子。
	_expect("chapter tabs resolve the dossier bitmap theme",
		(workspace.get_node("%ChapterNav") as Control).has_theme_stylebox(
			"pressed", "PKChapterTab"))
	_expect("country sheet is a cinnabar paper frame",
		_frame_edge(workspace, "SheetCard") == "cinnabar")
	_expect("war sheet is a cinnabar paper frame",
		_frame_edge(workspace, "WarSheetCard") == "cinnabar")

	host.queue_free()
	await process_frame


func _check_commands() -> void:
	var host := _theme_host()
	var workspace := (load(SCENE) as PackedScene).instantiate()
	host.add_child(workspace)
	await process_frame
	var controller := FakeController.new()
	workspace.set_player_controller(controller)
	workspace.set_model(_fixture_model())
	workspace.select_chapter("countries")
	await process_frame
	workspace.select_country(NEIGHBOUR_HANDLE)
	await process_frame
	var declare_button := workspace.get_node("%DeclareButton") as Button
	declare_button.pressed.emit()
	_expect("宣战 goes through the player command gateway",
		controller.commands.size() == 1
		and String(controller.commands[0].id) == "military.war.declare"
		and int(controller.commands[0].args.get("target", 0)) == NEIGHBOUR_HANDLE)
	await process_frame
	_expect("a submitted declaration disables the button until the next day",
		declare_button.disabled and declare_button.tooltip_text.contains("次日生效"))
	var status := workspace.get_node("%StatusLabel") as Label
	_expect("a submitted declaration leaves a receipt line",
		status.visible and status.text.contains("宣战"))
	host.queue_free()
	await process_frame


func _check_declare_blocked_by_soldiers() -> void:
	var vm = DiplomacyViewModel.new()
	vm.configure(_fixture_model(0))
	var roster: Array = vm.roster()
	var neighbour := _row(roster, NEIGHBOUR_HANDLE)
	_expect("a country with no soldiers cannot declare war",
		not bool(neighbour.can_declare)
		and String(neighbour.declare_reason).contains("无兵可战"))
	var overview: Dictionary = vm.overview_model()
	_expect("overview warns about the empty muster",
		String(overview.kpis[2].caption) == "无兵可战")
	var insights: Array = overview.insights
	var found := false
	for insight in insights:
		if String(insight.text) == "无兵可战":
			found = true
	_expect("overview states the empty muster plainly", found)


# ── fixture ──────────────────────────────────────────────────────────────

func _fixture_model(player_soldiers: int = 1200) -> Dictionary:
	var map := FakeMap.new()
	var country := FakeCountryFacade.new()
	var military := FakeMilitaryFacade.new()
	var generator := FakeGenerator.new(map)
	var snapshot := {
		"ok": true,
		"country_slot": PLAYER_SLOT,
		"country_handle": PLAYER_HANDLE,
		"soldiers_total": player_soldiers,
		"soldiers_militia": 200,
		"soldiers_trained": maxi(0, player_soldiers - 200),
		"soldiers_in_armies": 900,
		"post_count": 2,
		"barracks": [],
		"wars_active": 1,
		"wars": [{
			"war_id": WAR_ID,
			"attacker_slot": PLAYER_SLOT,
			"defender_slot": ENEMY_SLOT,
			"start_day": 351,
			"score_q16": int(0.27 * Q16),
			"attacker_losses": 2140,
			"defender_losses": 3980,
			"fully_occupied": false,
		}],
		"front_edge_keys": PackedInt32Array([4 * 6, 4 * 6 + 1]),
		"front_edge_progress": PackedByteArray([200, 255]),
	}
	return {
		"available": true,
		"country_handle": PLAYER_HANDLE,
		"country_name": "青川",
		"territory_count": 20,
		"current_day": DAY,
		"generator": generator,
		"country_facade": country,
		"good_ids": PackedStringArray(),
		"military": {
			"available": true,
			"facade": military,
			"country_handle": PLAYER_HANDLE,
			"country_handles": {ENEMY_SLOT: ENEMY_HANDLE, NEIGHBOUR_SLOT: NEIGHBOUR_HANDLE,
				FAR_SLOT: FAR_HANDLE, HIDDEN_SLOT: HIDDEN_HANDLE},
			"snapshot": snapshot,
			"armies": [],
			"catalog": {"ok": true, "units": [], "categories": []},
			"researched_tech_ids": PackedStringArray(),
			"tech_gate_known": false,
			"generator": generator,
		},
		"diplomacy": {
			"available": true,
			"reason": "",
			"generator": generator,
			"country_facade": country,
			"military_facade": military,
			"country_handle": PLAYER_HANDLE,
			"day": DAY,
			"military_available": true,
			"military_reason": "",
		},
	}


class FakeMap:
	var country_slot_arr := PackedInt32Array(OWNERS)
	var visible_arr := PackedByteArray()
	var explored_arr := PackedByteArray()
	var fog_solved := true
	var vision_revision := 3

	func _init() -> void:
		visible_arr.resize(CELLS)
		explored_arr.resize(CELLS)
		for cell in range(CELLS):
			visible_arr[cell] = 1 if cell < 16 else 0
			explored_arr[cell] = 0 if cell >= 36 else 1

	## 5 行 × 8 列 odd-r 偏移。fixture 不做东西向环绕：接壤判定才是可读的
	## 「隔着谁」而不是「刚好在接缝上」。
	func neighbor_indices_packed() -> PackedInt32Array:
		var out := PackedInt32Array()
		out.resize(CELLS * 6)
		for cell in range(CELLS):
			var row := cell / WIDTH
			var column := cell % WIDTH
			var odd := 1 if (row & 1) == 1 else 0
			var offsets := [Vector2i(1, 0), Vector2i(odd, -1), Vector2i(odd - 1, -1),
				Vector2i(odd - 1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
			for direction in range(6):
				var delta: Vector2i = offsets[direction]
				var next_row := row + delta.y
				var next_col := column + delta.x
				if next_row < 0 or next_row >= ROWS or next_col < 0 or next_col >= WIDTH:
					out[cell * 6 + direction] = -1
					continue
				out[cell * 6 + direction] = next_row * WIDTH + next_col
		return out


class FakeGenerator:
	var _map

	func _init(map) -> void:
		_map = map

	func current_map():
		return _map

	func get_country_facade():
		return FakeCountryFacade.new()

	func get_military_facade():
		return null

	func region_name_for_cell(_cell: int) -> String:
		return "青阳"


class FakeCountryFacade:
	func report() -> Dictionary:
		return {"generation": 5, "last_committed_day": DAY}

	func cell_summary(cell: int) -> Dictionary:
		if cell < 0 or cell >= CELLS:
			return {}
		var slot := int(OWNERS[cell])
		return {
			"ok": true,
			"owned": slot >= 0,
			"cell": cell,
			"country_slot": slot,
			"country_handle": int(HANDLES.get(slot, 0)),
			"country_name": String(NAMES.get(slot, "无主之地")),
			"territory_count": _cells_of(slot),
			"technology_count": 9,
			"cash": 12340000,
		}

	func current_era_index(_handle: int) -> int:
		return 2

	func snapshot(handle: int) -> Dictionary:
		return {"ok": true, "country_handle": handle, "country_name": _name_for(handle)}

	func _cells_of(slot: int) -> int:
		var total := 0
		for value in OWNERS:
			if int(value) == slot:
				total += 1
		return total

	func _name_for(handle: int) -> String:
		for slot in HANDLES:
			if int(HANDLES[slot]) == handle:
				return String(NAMES.get(slot, ""))
		return ""


class FakeMilitaryFacade:
	func country_snapshot(handle: int) -> Dictionary:
		var enemy := handle == ENEMY_HANDLE
		return {
			"ok": true,
			"country_handle": handle,
			"soldiers_total": 4200 if enemy else 900,
			"post_count": 3 if enemy else 1,
			"barracks": [{"cell": 4}, {"cell": 5}, {"cell": 12}] if enemy else [{"cell": 5}],
			"wars_active": 1 if enemy else 0,
		}

	func armies(handle: int) -> Array:
		return [{}, {}] if handle == ENEMY_HANDLE else []

	func control_snapshot() -> Dictionary:
		return {"ok": true, "cells": PackedInt32Array([4, 5]),
			"controller_slots": PackedInt32Array([PLAYER_SLOT, PLAYER_SLOT])}


class FakeController:
	var commands: Array = []

	func request_command(id: StringName, args: Dictionary) -> Dictionary:
		commands.append({"id": String(id), "args": args})
		return {"ok": true, "code": "queued", "message": "军事命令已排队"}

	func get_country_facade():
		return null


# ── helpers ──────────────────────────────────────────────────────────────

func _row(rows: Array, handle: int) -> Dictionary:
	for row in rows:
		if int(row.handle) == handle:
			return row
	return {}


func _fact(sheet: Dictionary, fact_id: String) -> Dictionary:
	for fact in sheet.get("facts", []):
		if String(fact.get("id", "")) == fact_id:
			return fact
	return {}


func _first_cell(slot: int) -> int:
	for index in range(CELLS):
		if int(OWNERS[index]) == slot:
			return index
	return -1


func _has_currency_unit(text: String) -> bool:
	for token in ["¥", "￥", "$", "元", "货币"]:
		if text.contains(token):
			return true
	return false


func _any_log_row_visible(workspace: Control) -> bool:
	for index in range(5):
		var label := workspace.get_node("%Log" + str(index)) as Label
		if label != null and label.visible:
			return true
	return false


## 工作区必须挂在一个带正式主题的宿主下：章节页签与纸框都靠主题变体解析，
## 直接挂到 SceneTree 根上会退化成未主题化的裸控件（与真实对局不符）。
func _theme_host() -> Control:
	var host := Control.new()
	host.theme = load(THEME) as Theme
	host.size = Vector2(1280, 720)
	root.add_child(host)
	return host


func _frame_edge(workspace: Control, card_name: String) -> String:
	var card := workspace.find_child(card_name, true, false)
	if card == null:
		return ""
	return String(card.get("edge"))


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		print("  [FAIL] %s" % label)
		_failures.append(label)
