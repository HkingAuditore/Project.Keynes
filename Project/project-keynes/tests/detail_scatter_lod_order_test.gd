extends SceneTree

# encode_detail_scatter LOD 前缀排序原生下沉的平价测试：
# 同一合成 knobs 跑两遍（lod_order_enabled=false/true），验证原生序与
# shrub_layer._lod_order_sources 的 GDScript 参考序满足同一契约：
#   1) far_count 完全相等；
#   2) 远场前缀的 (cell_idx, seed) 多重集一致（⇒ wrap cluster 不跨边界）；
#   3) 整段 buffer 的 (cell_idx, seed) 多重集一致（实例总体不变）。
# cluster 内部相对顺序（源实例 vs wrap 副本）不在契约内：同 seed 同 cell，
# 视觉等价。
#
# Headless:
#   godot --headless --path Project/project-keynes --script res://tests/detail_scatter_lod_order_test.gd

const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[lod-order] SKIP: DCWorldExt unavailable")
		return
	var layer = ShrubLayerScript.new()
	layer._map = MapData.new(24, 12)
	layer._hex_size = 10.0
	var multiplier := float(layer._resolved_lod_near_density_multiplier())

	var ext := DCWorldExt.new()
	var res_a: Dictionary = ext.call("encode_detail_scatter", _make_knobs(multiplier, false))
	_expect("unordered encode succeeds", not bool(res_a.get("fallback", true)))
	var res_b: Dictionary = ext.call("encode_detail_scatter", _make_knobs(multiplier, true))
	_expect("ordered encode succeeds", not bool(res_b.get("fallback", true)))
	_expect("ordered encode reports lod_ordered", bool(res_b.get("lod_ordered", false)))
	if bool(res_a.get("fallback", true)) or bool(res_b.get("fallback", true)):
		print("=== detail scatter lod order: %d checks, %d failures ===" % [_checks, _failures])
		return

	var inst_a := int(res_a.get("instance_count", 0))
	var inst_b := int(res_b.get("instance_count", 0))
	_expect("encode produces instances (got %d)" % inst_a, inst_a > 0)
	_expect("instance count identical across runs", inst_a == inst_b)
	if inst_a <= 0 or inst_a != inst_b:
		print("=== detail scatter lod order: %d checks, %d failures ===" % [_checks, _failures])
		return

	var buf_a: PackedFloat32Array = res_a.get("buffer", PackedFloat32Array())
	var cells_a: PackedInt32Array = res_a.get("cell_indices", PackedInt32Array())
	var buf_b: PackedFloat32Array = res_b.get("buffer", PackedFloat32Array())
	var cells_b: PackedInt32Array = res_b.get("cell_indices", PackedInt32Array())
	var native_far := int(res_b.get("far_count", -1))

	var src_indices: Array = []
	for i in range(inst_a):
		src_indices.append(i)
	var ref: Dictionary = layer._lod_order_sources(src_indices, cells_a, buf_a)
	var ref_order: Array = ref.get("order", [])
	var ref_far := int(ref.get("far_count", -1))

	_expect("far_count matches GDScript reference (native=%d ref=%d)" % [native_far, ref_far],
		native_far == ref_far)
	_expect("full buffer multiset matches",
		_multiset(buf_b, cells_b, 0, inst_b) == _multiset(buf_a, cells_a, 0, inst_a))
	_expect("far prefix multiset matches",
		_multiset(buf_b, cells_b, 0, native_far) == _multiset_reordered(buf_a, cells_a, ref_order, 0, ref_far))

	# 抽样验证 wrap cluster 原子性：前缀内任意 seed 的出现次数，要么等于全量中该
	# seed 的总数（cluster 完整保留），要么 0（完整剔除），不允许跨界拆分。
	var full_counts := _multiset(buf_b, cells_b, 0, inst_b)
	var prefix_counts := _multiset(buf_b, cells_b, 0, native_far)
	var atomic := true
	for key in prefix_counts.keys():
		if int(prefix_counts[key]) != int(full_counts.get(key, 0)):
			atomic = false
			break
	_expect("wrap clusters never straddle the far/near boundary", atomic)

	# 精确脏格缓存重组必须直接产出同一 LOD 前缀，不能再依赖一次全 chunk
	# GDScript 排序/复制；这是 succession 单格刷新热路径的性能契约。
	layer._cache_chunk_cell_payloads(7, buf_b, cells_b, inst_b)
	var assembled: Dictionary = layer._assemble_chunk_cell_payloads(
		layer._chunk_cell_payloads.get(7, {}))
	var assembled_buffer: PackedFloat32Array = assembled.get("buffer", PackedFloat32Array())
	var assembled_cells: PackedInt32Array = assembled.get("cell_indices", PackedInt32Array())
	var assembled_count := int(assembled.get("instance_count", 0))
	var assembled_far := int(assembled.get("far_count", -1))
	_expect("cache assembly preserves every instance", assembled_count == inst_b)
	_expect("cache assembly preserves the full multiset",
		_multiset(assembled_buffer, assembled_cells, 0, assembled_count) ==
		_multiset(buf_b, cells_b, 0, inst_b))
	_expect("cache assembly directly preserves the native far prefix",
		assembled_far == native_far and
		_multiset(assembled_buffer, assembled_cells, 0, assembled_far) ==
		_multiset(buf_b, cells_b, 0, native_far))

	layer.free()
	print("=== detail scatter lod order: %d checks, %d failures ===" % [_checks, _failures])


func _make_knobs(multiplier: float, ordered: bool) -> Dictionary:
	var grid_w := 24
	var grid_h := 12
	var hex_size := 10.0
	var period := 360.0
	var offw := PackedByteArray()
	offw.resize(grid_w * grid_h)
	offw.fill(0)
	var keys := PackedInt32Array()
	var cells := PackedInt32Array()
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var suit := PackedFloat32Array()
	var att := PackedInt32Array()
	var vit := PackedFloat32Array()
	var sized := PackedFloat32Array()
	var cr := PackedFloat32Array()
	var cg := PackedFloat32Array()
	var cb := PackedFloat32Array()
	var ca := PackedFloat32Array()
	# 乱序 cell id；贴左右边缘的 cell 用来制造同 seed 的 wrap 副本。
	var defs := [
		[1001, 170, period - 3.0, 40.0],
		[1002, 42, 3.0, 40.0],
		[1003, 900, 120.0, 90.0],
		[1004, 5, 1.5, 90.0],
		[1005, 300, period * 0.5, 60.0],
		[1006, 42, 300.0, 130.0],
	]
	for d in defs:
		keys.append(int(d[0]))
		cells.append(int(d[1]))
		cx.append(float(d[2]))
		cy.append(float(d[3]))
		suit.append(1.0)
		att.append(64)
		vit.append(1.0)
		sized.append(1.0)
		cr.append(0.5)
		cg.append(0.6)
		cb.append(0.4)
		ca.append(1.0)
	return {
		"hex_size": hex_size,
		"origin_x": 0.0,
		"origin_y": 0.0,
		"size_x": period,
		"size_y": 200.0,
		"wrap_period_x": period,
		"wrap_edge_margin": hex_size * 2.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offw,
		"flow_buffer": PackedFloat32Array(),
		"flow_w": 0,
		"flow_h": 0,
		"keys": keys,
		"cell_indices": cells,
		"center_x": cx,
		"center_y": cy,
		"suitability": suit,
		"attempts": att,
		"vitality": vit,
		"size_density": sized,
		"color_r": cr,
		"color_g": cg,
		"color_b": cb,
		"color_a": ca,
		"spawn_domain": 2,
		"instance_cap": 100000,
		"micro_gap_threshold": -1.0,
		"world_noise_acceptance": 10.0,
		"vitality_dieback_noise_strength": 0.0,
		"lod_order_enabled": ordered,
		"lod_near_density_multiplier": multiplier,
	}


func _seed_key(buffer: PackedFloat32Array, cell_indices: PackedInt32Array, i: int) -> String:
	return "%d|%s" % [int(cell_indices[i]), str(buffer[i * 16 + 14])]


func _multiset(buffer: PackedFloat32Array, cell_indices: PackedInt32Array,
		start: int, end: int) -> Dictionary:
	var out := {}
	for i in range(start, end):
		var key := _seed_key(buffer, cell_indices, i)
		out[key] = int(out.get(key, 0)) + 1
	return out


func _multiset_reordered(buffer: PackedFloat32Array, cell_indices: PackedInt32Array,
		order: Array, start: int, end: int) -> Dictionary:
	var out := {}
	for i in range(start, end):
		var src := int(order[i])
		var key := _seed_key(buffer, cell_indices, src)
		out[key] = int(out.get(key, 0)) + 1
	return out


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
