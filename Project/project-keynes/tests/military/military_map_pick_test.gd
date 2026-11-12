extends SceneTree

## 军务档案的地图拾取契约：
##   1) 部队棋子优先于战线，战线优先于格选择；
##   2) 同格重叠时取兵力更大的一支；
##   3) 迷雾里看不见的外国部队不可拾取；
##   4) 同一条物理边从两侧点击得到同一个 key；
##   5) 战线扇区沿共享格展开成一段连续战线。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_map_pick_test.gd

const LAYERS_SCRIPT := preload("res://scripts/rendering/military_map_layers.gd")
const FEED_SCRIPT := preload("res://scripts/rendering/military_render_feed.gd")
const HEIGHT := 7
const WIDTH := 9
const HEX := 22.0
const LF = LandformType.LF

var _failures := PackedStringArray()
var _map: MapData
var _manager
var _key_ab := -1
var _key_bc := -1
var _cell_a := -1
var _cell_b := -1
var _cell_c := -1
var _cell_d := -1


class FakeExt:
	var snapshot: Dictionary = {}

	func get_military_render_snapshot(_after_revision: int) -> Dictionary:
		return snapshot


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_map = _make_map()
	_cell_a = _index_at(_map, 2, 3)
	_cell_b = _index_at(_map, 3, 3)
	_cell_c = _index_at(_map, 4, 3)
	_cell_d = _index_at(_map, 6, 5)
	_key_ab = _edge_key(_cell_a, _cell_b)
	_key_bc = _edge_key(_cell_b, _cell_c)
	_expect(_key_ab >= 0 and _key_bc >= 0, "front keys resolve from the map topology")

	_manager = LAYERS_SCRIPT.new()
	get_root().add_child(_manager)
	await process_frame
	_manager.configure(_map, null, null, null, null)
	var ext := FakeExt.new()
	ext.snapshot = _build_snapshot()
	_manager._ext = ext
	_manager._feed = FEED_SCRIPT.new()
	_manager._player_slot = 0
	_manager._poll()
	await process_frame

	await _test_army_wins()
	await _test_empty_cell_falls_through()
	await _test_front_edge_pick()
	await _test_canonical_key_symmetry()
	await _test_fog_gate()
	await _test_sector_expands()
	_manager.queue_free()
	await process_frame
	_finish()


func _build_snapshot() -> Dictionary:
	return {
		"ok": true,
		"available": true,
		"revision": 1,
		"armies": {
			"handle": PackedInt64Array([101, 202]),
			"owner_slot": PackedInt32Array([0, 1]),
			"cell": PackedInt32Array([_cell_a, _cell_d]),
			"prev_cell": PackedInt32Array([_cell_a, _cell_d]),
			"moved_day": PackedInt32Array([0, 0]),
			"unit_class": PackedByteArray([0, 0]),
			"headcount": PackedInt64Array([120, 80]),
			"flags": PackedInt32Array([0, 0]),
		},
		"engagements": {
			"cell_a": PackedInt32Array([_cell_a]),
			"cell_b": PackedInt32Array([_cell_b]),
			"progress_q16": PackedInt32Array([32768]),
			"attacker_slot": PackedInt32Array([0]),
			"battle": PackedByteArray([1]),
		},
		"convoys": {},
		"controller_cells": PackedInt32Array(),
		"controller_slots": PackedInt32Array(),
		"control_revision": 0,
		"front_edges": PackedInt32Array([_key_ab, _key_bc]),
		"front_progress": PackedByteArray([128, 255]),
		"front_revision": 1,
		"selected_army": 0,
	}


func _test_army_wins() -> void:
	var pick: Dictionary = _manager.pick_at_world(_cell_world(_cell_a))
	_expect(String(pick.get("kind", "")) == "army",
		"clicking a token picks the army before the front ribbon")
	_expect(int(pick.get("handle", 0)) == 101, "picked handle is the army on that cell")
	_expect(int(pick.get("cell", -1)) == _cell_a, "picked cell is the army cell")


func _test_empty_cell_falls_through() -> void:
	var pick: Dictionary = _manager.pick_at_world(_cell_world(_cell_c))
	_expect(pick.is_empty(), "a quiet cell centre belongs to cell selection, not the dossier")


func _test_front_edge_pick() -> void:
	var mid: Vector2 = _manager.front_edge_anchor_world(_key_ab)
	var pick: Dictionary = _manager.pick_at_world(mid)
	_expect(String(pick.get("kind", "")) == "front", "the ribbon midpoint picks the front")
	_expect(int(pick.get("edge", -1)) == _key_ab, "the picked edge is the clicked ribbon")
	var far := mid + Vector2(0.0, HEX * 1.2)
	_expect(String(_manager.pick_at_world(far).get("kind", "")) != "front",
		"clicks far from the ribbon do not steal the front")


func _test_canonical_key_symmetry() -> void:
	_expect(_edge_key(_cell_b, _cell_a) == _key_ab,
		"both sides of a physical edge resolve to one key")


func _test_fog_gate() -> void:
	_map.visible_arr[_cell_d] = 0
	_manager._feed.apply_fog(_map, true)
	# 拾取跟随"画出来的东西"：迷雾变化后要等图层把可见性推下来。
	_manager._push_layers(true)
	_expect(_manager.pick_at_world(_cell_world(_cell_d)).is_empty(),
		"an unseen foreign army cannot be picked")
	_expect(_manager.armies_at_cell(_cell_d).is_empty(),
		"the same-cell roster also hides unseen armies")
	_map.visible_arr[_cell_d] = 1
	_manager._feed.apply_fog(_map, false)
	_manager._push_layers(false)
	_expect(not _manager.armies_at_cell(_cell_d).is_empty(),
		"a visible army is listed in the same-cell roster")


func _test_sector_expands() -> void:
	var sector: Dictionary = _manager.front_sector(_key_ab)
	_expect(bool(sector.get("ok", false)), "front_sector answers for a live front edge")
	_expect(int(sector.get("edge_count", 0)) == 2,
		"the sector walks both edges of the tested front (got %d)"
			% int(sector.get("edge_count", 0)))
	_expect(int(sector.get("active_count", 0)) == 1,
		"the sector counts only the engaged edge as active")
	var engagements: Array = sector.get("engagements", [])
	_expect(engagements.size() == 1, "the sector matches the engagement on its edge")
	_expect(int(sector.get("focus_cell", -1)) >= 0, "the sector carries a focus cell")
	_expect(absf(float(sector.get("advance", -1.0))) >= 0.0,
		"the sector reports an advance ratio")
	var sides: Array = sector.get("sides", [])
	_expect(sides.size() >= 1, "the sector aggregates visible armies by side")
	_expect(_manager.front_sector(_key_ab + 99999).is_empty(),
		"an unknown edge yields no sector")


## 与原生一致：一条物理边由「较小格 + 方向」持有。
func _edge_key(a: int, b: int) -> int:
	var low := mini(a, b)
	var high := maxi(a, b)
	var neighbors: PackedInt32Array = _map.neighbor_indices_packed()
	for dir in 6:
		var index := low * 6 + dir
		if index < neighbors.size() and int(neighbors[index]) == high:
			return index
	return -1


func _cell_world(cell: int) -> Vector2:
	var cell_obj = _map.cell_at(int(cell))
	return HexUtils.cube_to_world(cell_obj.q, cell_obj.r, HEX)


func _make_map() -> MapData:
	var map := MapData.new(WIDTH, HEIGHT)
	for row in range(HEIGHT):
		for col in range(WIDTH):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LF.PLAIN
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	if map.visible_arr.size() < WIDTH * HEIGHT:
		map.visible_arr.resize(WIDTH * HEIGHT)
	map.visible_arr.fill(1)
	return map


func _index_at(map: MapData, col: int, row: int) -> int:
	var cell := map.get_cell_by_cube(HexUtils.offset_to_cube(col, row))
	return int(cell.index) if cell != null else -1


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("=== military map pick test: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
