# vision_solver_test.gd
# VisionSolver 的地形感知、单调 explored 与三态门控。
#
#   godot --headless --script tests/vision_solver_test.gd --quit
extends SceneTree

const WIDTH := 15
const HEIGHT := 11
const LF = LandformType.LF
const VEG = VegetationType.VEG

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_flat_terrain_radius()
	_test_terrain_awareness()
	_test_source_probe_matches_solve()
	_test_explored_is_monotonic()
	_test_fog_state_and_disabled_path()
	print("vision solver: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_source_probe_matches_solve() -> void:
	var map := _make_map(LF.HILL, VEG.TEMPERATE_GRASSLAND)
	var world := WorldData.new()
	var src := _center_index(map)
	var probe := VisionSolver.compute_visible_for_sources(
		map, world, PackedInt32Array([src]))
	map.country_slot_arr[src] = 0
	VisionSolver.solve(map, world, 0)
	_expect("startup probe matches formal vision solve",
		bool(probe.get("ok", false)) and probe.visible == map.visible_arr)


## 平原上：源格必可见，可见集连通且远小于全图，边界不可见。
func _test_flat_terrain_radius() -> void:
	var map := _make_map(LF.PLAIN, VEG.NONE)
	var world := WorldData.new()
	var src := _center_index(map)
	map.country_slot_arr[src] = 0
	var report: Dictionary = VisionSolver.solve(map, world, 0)
	_expect("flat solve succeeds", bool(report.get("ok", false)))
	_expect("source cell is visible", map.visible_arr[src] == 1)
	var visible := int(report.get("visible", 0))
	_expect("flat vision is bounded", visible > 6 and visible < map.cell_count())
	_expect("explored covers exactly the visible set on first solve",
		int(report.get("explored", 0)) == visible)
	_expect("k is saturated at the source", map.fog_k_arr[src] >= 200)
	_expect("k is zero far from the source", map.fog_k_arr[_far_index(map, src)] == 0)


## 山顶看得远、雨林里看得近。这是「地形感知」这条设计成立与否的唯一硬指标。
func _test_terrain_awareness() -> void:
	var peak_map := _make_map(LF.PLAIN, VEG.NONE)
	var peak_src := _center_index(peak_map)
	peak_map.country_slot_arr[peak_src] = 0
	peak_map.landform_arr[peak_src] = LF.PEAK
	var peak: Dictionary = VisionSolver.solve(peak_map, WorldData.new(), 0)

	var flat_map := _make_map(LF.PLAIN, VEG.NONE)
	var flat_src := _center_index(flat_map)
	flat_map.country_slot_arr[flat_src] = 0
	var flat: Dictionary = VisionSolver.solve(flat_map, WorldData.new(), 0)

	var jungle_map := _make_map(LF.PLAIN, VEG.TROPICAL_RAINFOREST)
	var jungle_src := _center_index(jungle_map)
	jungle_map.country_slot_arr[jungle_src] = 0
	var jungle: Dictionary = VisionSolver.solve(jungle_map, WorldData.new(), 0)

	_expect("a peak sees further than flat ground",
		int(peak.get("visible", 0)) > int(flat.get("visible", 0)))
	_expect("rainforest blocks more sight than open plain",
		int(jungle.get("visible", 0)) < int(flat.get("visible", 0)))


## explored 只增不减：领土迁走之后，旧领土仍然是「已探索」，而不再「可见」。
func _test_explored_is_monotonic() -> void:
	var map := _make_map(LF.PLAIN, VEG.NONE)
	var world := WorldData.new()
	var first := _center_index(map)
	map.country_slot_arr[first] = 0
	var before: Dictionary = VisionSolver.solve(map, world, 0)
	var explored_before := int(before.get("explored", 0))

	map.country_slot_arr[first] = -1
	var second := _index_at(map, 1, 1)
	map.country_slot_arr[second] = 0
	var after: Dictionary = VisionSolver.solve(map, world, 0)

	_expect("relocated territory keeps prior exploration",
		int(after.get("explored", 0)) >= explored_before)
	_expect("abandoned homeland is explored but no longer visible",
		map.explored_arr[first] == 1 and map.visible_arr[first] == 0)
	_expect("abandoned homeland reads as FOG_EXPLORED",
		VisionSolver.fog_state(map, first) == VisionSolver.FOG_EXPLORED)
	_expect("new homeland reads as FOG_VISIBLE",
		VisionSolver.fog_state(map, second) == VisionSolver.FOG_VISIBLE)


## 三态门控与「迷雾关闭」直通路径。UI 与 shader 都只认这三个数组，
## 所以关掉迷雾必须表现成「全图已探索且可见」，而不是各消费点自己再判一次开关。
func _test_fog_state_and_disabled_path() -> void:
	var map := _make_map(LF.PLAIN, VEG.NONE)
	var src := _center_index(map)
	map.country_slot_arr[src] = 0
	VisionSolver.solve(map, WorldData.new(), 0)
	_expect("distant cell reads as FOG_UNEXPLORED",
		VisionSolver.fog_state(map, _far_index(map, src)) == VisionSolver.FOG_UNEXPLORED)

	var disabled: Dictionary = VisionSolver.mark_all_visible(map)
	_expect("disabled fog marks every cell visible",
		int(disabled.get("visible", 0)) == map.cell_count())
	_expect("disabled fog saturates k everywhere", map.fog_k_arr[0] == 255 \
		and map.fog_k_arr[map.cell_count() - 1] == 255)

	# 数组从未解算过时必须放行，否则没接线的测试场景会被界面锁死。
	var fresh := _make_map(LF.PLAIN, VEG.NONE)
	fresh.visible_arr = PackedByteArray()
	fresh.explored_arr = PackedByteArray()
	_expect("unsolved map falls back to fully visible",
		VisionSolver.fog_state(fresh, 0) == VisionSolver.FOG_VISIBLE)


# --- 测试夹具 -------------------------------------------------

func _make_map(landform: int, vegetation: int) -> MapData:
	var map := MapData.new(WIDTH, HEIGHT)
	for row in range(HEIGHT):
		for col in range(WIDTH):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = landform
			cell.vegetation = vegetation
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	map.country_slot_arr.resize(map.cell_count())
	for i in range(map.cell_count()):
		map.country_slot_arr[i] = -1
	return map


func _index_at(map: MapData, col: int, row: int) -> int:
	var cell := map.get_cell_by_cube(HexUtils.offset_to_cube(col, row))
	return int(cell.index) if cell != null else -1


func _center_index(map: MapData) -> int:
	return _index_at(map, WIDTH / 2, HEIGHT / 2)


## 与源格隔了整整半张图的格子，保证落在任何合理视距之外。
func _far_index(map: MapData, _src: int) -> int:
	return _index_at(map, 0, 0)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
