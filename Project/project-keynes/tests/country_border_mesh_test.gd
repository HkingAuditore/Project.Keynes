# country_border_mesh_test.gd
# CountryBorderLayer 的边界拓扑：边数、去重规则、wrap 副本、国色稳定性。
#
#   godot --headless --script tests/country_border_mesh_test.gd --quit
extends SceneTree

const BorderLayerScript = preload("res://scripts/rendering/country_border_layer.gd")
const WIDTH := 12
const HEIGHT := 9
const LF = LandformType.LF

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_single_cell_country()
	_test_ribbons_meet_at_corners()
	_test_shared_border_emits_both_sides()
	_test_unowned_map_is_empty()
	_test_wrap_tiling()
	_test_country_colors()
	print("country border mesh: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 孤立一格：6 条边全是国界，24 个顶点。
func _test_single_cell_country() -> void:
	var map := _make_map()
	map.country_slot_arr[_index_at(map, 5, 4)] = 0
	var stats := _rebuild(map, 0.0)
	_expect("an isolated cell emits all six edges", int(stats.edges) == 6)
	_expect("each edge is a four-vertex ribbon quad", int(stats.vertices) == 24)
	_expect("one country is coloured", int(stats.countries) == 1)


## 回归：相邻 ribbon 必须正好在 hex 角点汇合。
##
## 早期版本把四个顶点都沿边方向向外延伸（本意是 miter，方向反了），于是每条边
## 都越过两端角点，相邻两条在角外交叉——放大后是肉眼可见的 X。原有断言只数边数
## 和顶点数，全部照过。这里改为检查外缘端点：6 条边共 12 个外缘端点，相邻两条
## 共享角点，去重后必须正好剩 6 个；越界时会退化成 12 个互不重合的点。
func _test_ribbons_meet_at_corners() -> void:
	var map := _make_map()
	map.country_slot_arr[_index_at(map, 5, 4)] = 0
	var layer = BorderLayerScript.new()
	layer.set_hex_size(22.0)
	layer.set_horizontal_wrap(0.0)
	layer.set_player_slot(0)
	layer.rebuild(map)
	var verts := _outer_edge_endpoints(layer)
	layer.free()

	var unique: Array[Vector2] = []
	for p in verts:
		var seen := false
		for q in unique:
			if q.distance_to(p) < 0.01:
				seen = true
				break
		if not seen:
			unique.append(p)
	_expect("ribbon outer edges are emitted for all six sides", verts.size() == 12)
	_expect("adjacent ribbons meet exactly at the hex corners (no overshoot)",
		unique.size() == 6)


## 取每条 ribbon 的前两个顶点（外缘两端）。顶点按 4 个一组写入。
func _outer_edge_endpoints(layer) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var mesh_inst := layer.get_node_or_null("BorderMesh") as MeshInstance2D
	if mesh_inst == null or mesh_inst.mesh == null:
		return out
	var raw: Variant = mesh_inst.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var count: int = 0
	if raw is PackedVector2Array:
		count = (raw as PackedVector2Array).size()
	elif raw is PackedVector3Array:
		count = (raw as PackedVector3Array).size()
	for i in range(0, count, 4):
		for k in [0, 1]:
			if raw is PackedVector2Array:
				out.append((raw as PackedVector2Array)[i + k])
			else:
				var v: Vector3 = (raw as PackedVector3Array)[i + k]
				out.append(Vector2(v.x, v.y))
	return out


## 相邻两国共享的那条边由两侧各出一条 ribbon —— 这是「深色分隔线 + 两侧国色带」
## 观感的来源，也是为什么这里不做按 idx 去重。
func _test_shared_border_emits_both_sides() -> void:
	var map := _make_map()
	var a := _index_at(map, 5, 4)
	var b := map.neighbor_index(a, 0)
	map.country_slot_arr[a] = 0
	map.country_slot_arr[b] = 1
	var stats := _rebuild(map, 0.0)
	# 每格 6 条边全部临界（各自的另外 5 个邻居都无主），共享边两侧各算一条。
	_expect("both owners emit their own ribbon on the shared edge",
		int(stats.edges) == 12)
	_expect("two countries are coloured", int(stats.countries) == 2)

	# 同一个国家的两格之间不该有线。
	map.country_slot_arr[b] = 0
	var merged := _rebuild(map, 0.0)
	_expect("same-owner interior edges are suppressed", int(merged.edges) == 10)
	_expect("merged territory is a single country", int(merged.countries) == 1)


func _test_unowned_map_is_empty() -> void:
	var stats := _rebuild(_make_map(), 0.0)
	_expect("an unowned map produces no border geometry",
		int(stats.edges) == 0 and int(stats.vertices) == 0)


## 圆柱地图：mesh 复制 -period / 0 / +period 三份，边数统计按副本数归一。
func _test_wrap_tiling() -> void:
	var map := _make_map()
	map.country_slot_arr[_index_at(map, 5, 4)] = 0
	var stats := _rebuild(map, 600.0)
	_expect("wrapping bakes three tiles", int(stats.tiles) == 3)
	_expect("edge count is reported per tile", int(stats.edges) == 6)
	_expect("vertex count covers every tile", int(stats.vertices) == 72)


## 国色只依赖 slot：跨存档、跨遍历顺序稳定，且玩家国家永远是那一个固定色。
func _test_country_colors() -> void:
	var player := Color(0.96, 0.82, 0.36)
	_expect("player slot takes the reserved colour",
		BorderLayerScript.country_color(3, 3, player) == player)
	_expect("colour is a pure function of the slot",
		BorderLayerScript.country_color(7, 3, player) \
			== BorderLayerScript.country_color(7, 3, player))
	_expect("adjacent slots are visually distinct",
		BorderLayerScript.country_color(4, 3, player).h \
			!= BorderLayerScript.country_color(5, 3, player).h)
	_expect("unowned territory is fully transparent",
		BorderLayerScript.country_color(-1, 3, player).a == 0.0)


# --- 测试夹具 -------------------------------------------------

func _rebuild(map: MapData, wrap_period_x: float) -> Dictionary:
	var layer = BorderLayerScript.new()
	layer.set_hex_size(22.0)
	layer.set_horizontal_wrap(wrap_period_x)
	layer.set_player_slot(0)
	var stats: Dictionary = layer.rebuild(map)
	layer.free()
	return stats


func _make_map() -> MapData:
	var map := MapData.new(WIDTH, HEIGHT)
	for row in range(HEIGHT):
		for col in range(WIDTH):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LF.PLAIN
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	return map


func _index_at(map: MapData, col: int, row: int) -> int:
	var cell := map.get_cell_by_cube(HexUtils.offset_to_cube(col, row))
	return int(cell.index) if cell != null else -1


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
