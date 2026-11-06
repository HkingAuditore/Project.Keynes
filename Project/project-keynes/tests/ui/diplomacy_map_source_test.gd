extends SceneTree

## 归属与句柄解析的回归测试（生产链路）。
##
## 三处曾经只在 fixture 里成立的假设，让「宣战」与「割地」在生产环境一动不动：
##   1. 每格归属只认 `ext.get_country_cell_snapshot()`——C++ 里根本没有这条绑定；
##   2. 邻国/占领候选的扫描要求上面那条方法存在，否则直接返回空；
##   3. 国家句柄只来自模型里的 `country_handles`——生产链路从不填充它。
##
## 这里的世界只有 `MapData.country_slot_arr` 与 Country 的 `cell_summary()`：
## 没有 `get_data_core_world_ext`、没有 `country_handles` 覆盖表、国家快照里也没有
## `control` 段。这三条路必须仍然能算出邻国、句柄与割地候选。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/ui/diplomacy_map_source_test.gd

const Q16 := 65536
const DAY := 400
const PLAYER_SLOT := 0
const ENEMY_SLOT := 3
const PLAYER_HANDLE := 0x100000000
const ENEMY_HANDLE := 0x300000001
const WAR_ID := 11
const CELLS := 12
const ROWS := 2
const WIDTH := 6
## 2 行 × 6 列：左边本国，右边敌国，中间一条直线边界。
const OWNERS := [
	0, 0, 0, 3, 3, 3,
	0, 0, 0, 3, 3, 3,
]
## 我方控制、但归属敌国的格（占领）。
const CONTROLLED := [3, 4]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_factor = 1.0
	_check_military_view_model()
	_check_peace_candidates()
	_check_diplomacy_roster()
	print("diplomacy map source: %d failures" % _failures.size())
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	quit(0 if _failures.is_empty() else 1)


func _check_military_view_model() -> void:
	var vm = MilitaryViewModel.new()
	vm.configure(_military_model())
	var targets: Array = vm.declare_candidates()
	_expect("neighbour scan reads MapData.country_slot_arr without the old ext",
		targets.size() == 1)
	if targets.is_empty():
		return
	_expect("neighbour slot is the enemy", int(targets[0].slot) == ENEMY_SLOT)
	_expect("country handle is resolved through Country's cell summary",
		int(targets[0].handle) == ENEMY_HANDLE)
	_expect("neighbour scan counts the adjoining enemy cells",
		int(targets[0].cells) > 0)
	_expect("already being at war blocks a second declaration",
		not bool(targets[0].can_declare)
		and String(targets[0].reason) == "正在交战")
	_expect("neighbour name comes from Country",
		String(targets[0].name) == "赤原")


func _check_peace_candidates() -> void:
	var vm = MilitaryViewModel.new()
	vm.configure(_military_model())
	var war: Dictionary = vm.war_cards()[0] if not vm.war_cards().is_empty() else {}
	_expect("war card resolves for the peace draft", not war.is_empty())
	var ceded: Dictionary = vm.ceded_cells(war, {})
	_expect("cession candidates come from the facade's control snapshot",
		int(ceded.get("total", 0)) == CONTROLLED.size())
	var selected: Array = ceded.get("cells", [])
	_expect("checked cession cells are the controlled enemy cells",
		selected.size() == CONTROLLED.size()
		and int(selected[0]) == int(CONTROLLED[0])
		and int(selected[1]) == int(CONTROLLED[1]))


func _check_diplomacy_roster() -> void:
	var vm = DiplomacyViewModel.new()
	vm.configure(_diplomacy_model())
	var roster: Array = vm.roster()
	_expect("roster is built from the territory mirror", roster.size() == 1)
	if roster.is_empty():
		return
	_expect("roster row resolves the handle through Country",
		int(roster[0].handle) == ENEMY_HANDLE)
	_expect("roster row names the country", String(roster[0].name) == "赤原")
	_expect("roster row is a belligerent", String(roster[0].relation.state) == "war")
	_expect("a belligerent cannot be declared on again",
		not bool(roster[0].can_declare)
		and String(roster[0].declare_reason) == "正在交战")

	# 没有任何世界对象时，模型里的 fixture 兜底仍然有效（截图 harness 依赖它）。
	var stand_in := CountryMapQuery.owner_map(null, {
		"military": {"cell_owners": {"owners": PackedInt32Array(OWNERS)}},
	})
	_expect("owner map falls back to the model stand-in",
		stand_in == PackedInt32Array(OWNERS))


# ── fixture ──────────────────────────────────────────────────────────────

func _snapshot() -> Dictionary:
	return {
		"ok": true,
		"country_slot": PLAYER_SLOT,
		"country_handle": PLAYER_HANDLE,
		"soldiers_total": 800,
		"wars_active": 1,
		# 注意：没有 `control` 段——原生国家快照就是这样。
		"wars": [{
			"war_id": WAR_ID,
			"attacker_slot": PLAYER_SLOT,
			"defender_slot": ENEMY_SLOT,
			"start_day": 380,
			"score_q16": int(0.12 * Q16),
			"attacker_losses": 120,
			"defender_losses": 340,
			"fully_occupied": false,
		}],
		"front_edge_keys": PackedInt32Array([2 * 6 + 0]),
		"front_edge_progress": PackedByteArray([255]),
	}


func _military_model() -> Dictionary:
	var generator := FakeGenerator.new()
	return {
		"available": true,
		"country_handle": PLAYER_HANDLE,
		"country_name": "青川",
		"territory_count": 6,
		"current_day": DAY,
		"generator": generator,
		"country_facade": FakeCountryFacade.new(),
		"good_ids": PackedStringArray(),
		"military": {
			"available": true,
			"facade": FakeMilitaryFacade.new(),
			"country_handle": PLAYER_HANDLE,
			# 生产链路不填充这张表：句柄必须自己解析出来。
			"snapshot": _snapshot(),
			"armies": [],
			"catalog": {"ok": true, "units": [], "categories": []},
			"researched_tech_ids": PackedStringArray(),
			"tech_gate_known": false,
			"generator": generator,
		},
	}


func _diplomacy_model() -> Dictionary:
	var model := _military_model()
	model["diplomacy"] = {
		"available": true,
		"reason": "",
		"generator": model.generator,
		"country_facade": model.country_facade,
		"military_facade": model.military.facade,
		"country_handle": PLAYER_HANDLE,
		"day": DAY,
		"military_available": true,
		"military_reason": "",
	}
	return model


class FakeMap:
	var country_slot_arr := PackedInt32Array(OWNERS)
	var visible_arr := PackedByteArray()
	var explored_arr := PackedByteArray()
	var fog_solved := true
	var vision_revision := 1

	func _init() -> void:
		visible_arr.resize(CELLS)
		explored_arr.resize(CELLS)
		for cell in range(CELLS):
			visible_arr[cell] = 1
			explored_arr[cell] = 1

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


## 生产里的 MapGenerator 有 `current_map()` / `get_country_facade()`，但**没有**
## `get_data_core_world_ext()` 这一条老路（或者没有 `get_country_cell_snapshot`）。
class FakeGenerator:
	func current_map():
		return FakeMap.new()

	func get_country_facade():
		return FakeCountryFacade.new()

	func get_military_facade():
		return FakeMilitaryFacade.new()

	func region_name_for_cell(_cell: int) -> String:
		return "青阳"


class FakeCountryFacade:
	func report() -> Dictionary:
		return {"generation": 2, "last_committed_day": DAY}

	func cell_summary(cell: int) -> Dictionary:
		if cell < 0 or cell >= CELLS:
			return {}
		var slot := int(OWNERS[cell])
		return {
			"ok": true,
			"owned": slot >= 0,
			"cell": cell,
			"country_slot": slot,
			"country_handle": PLAYER_HANDLE if slot == PLAYER_SLOT else ENEMY_HANDLE,
			"country_name": "青川" if slot == PLAYER_SLOT else "赤原",
			"territory_count": 6,
			"technology_count": 4,
			"cash": 1000000,
		}

	func current_era_index(_handle: int) -> int:
		return 1

	func snapshot(handle: int) -> Dictionary:
		return {
			"ok": true,
			"country_handle": handle,
			"country_name": "赤原" if handle == ENEMY_HANDLE else "青川",
		}


class FakeMilitaryFacade:
	func country_snapshot(handle: int) -> Dictionary:
		var row := _snapshot_like()
		row["country"] = handle
		return row

	func armies(_handle: int) -> Array:
		return []

	## 占领快照只在 facade 上，不在国家快照里（原生就是这样分家的）。
	func control_snapshot() -> Dictionary:
		return {
			"ok": true,
			"cells": PackedInt32Array(CONTROLLED),
			"controller_slots": PackedInt32Array([PLAYER_SLOT, PLAYER_SLOT]),
			"count": CONTROLLED.size(),
		}

	func _snapshot_like() -> Dictionary:
		return {"ok": true, "soldiers_total": 800, "post_count": 1, "barracks": []}


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		print("  [FAIL] %s" % label)
		_failures.append(label)
