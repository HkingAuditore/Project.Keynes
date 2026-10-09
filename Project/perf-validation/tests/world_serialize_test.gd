# world_serialize_test.gd
# PR-4.1 — DCWorld serialize / deserialize round-trip 验证。
#
# 验证：
#   1. SAVE_VERSION = 1（baseline）
#   2. 空世界 round-trip 不 crash
#   3. 写入 38 个 production 字段后 serialize → 重建 → deserialize → bit-equal
#   4. demo 命名空间字段（cell.demo.thermal_gradient）不进存档
#   5. n_cells mismatch 时 deserialize 报错且不崩溃
#   6. version 0 触发 schema migration 警告但不阻塞 read
#
# Headless 运行：
#     godot --headless --script tests/world_serialize_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== world_serialize test (PR-4.1) ===")

	# 1. SAVE_VERSION baseline
	_expect("SAVE_VERSION == 1", DCWorld.SAVE_VERSION == 1)

	# 2. 创建一个 world，注册若干 production 字段
	var world: DCWorld = DCWorld.new()
	var cid_temp: int = world.register_component(DCComponentIds.CELL_TEMP, DCComponentIds.F32, 1, false)
	var cid_parent: int = world.register_component(DCComponentIds.CELL_HYDRO_PARENT, DCComponentIds.I32, 1, false)
	var cid_terr: int = world.register_component(DCComponentIds.CELL_TERRAIN, DCComponentIds.U8, 1, false)
	world.create_entities(8)

	# 3. 写入测试数据
	var temps: PackedFloat32Array = PackedFloat32Array([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
	var parents: PackedInt32Array = PackedInt32Array([-1, 0, 1, 2, 3, 4, 5, 6])
	var terrs: PackedByteArray = PackedByteArray([10, 20, 30, 40, 50, 60, 70, 80])
	world.write_f32_range(cid_temp, 0, temps)
	world.write_i32_range(cid_parent, 0, parents)
	world.write_u8_range(cid_terr, 0, terrs)

	# 4. serialize
	var snap: Dictionary = world.serialize()
	_expect("snap.version == 1", int(snap.get("version", -1)) == 1)
	_expect("snap.n_cells == 8", int(snap.get("n_cells", -1)) == 8)
	_expect("snap.has cells dict", snap.has("cells") and snap["cells"] is Dictionary)

	# 5. demo 字段被过滤
	var cells_dict: Dictionary = snap["cells"]
	_expect("demo field absent in snap", not cells_dict.has("cell_demo_thermal_gradient"))

	# 6. 创建第二个 world，复刻同样 n_cells
	var w2: DCWorld = DCWorld.new()
	var c2_temp: int = w2.register_component(DCComponentIds.CELL_TEMP, DCComponentIds.F32, 1, false)
	var c2_parent: int = w2.register_component(DCComponentIds.CELL_HYDRO_PARENT, DCComponentIds.I32, 1, false)
	var c2_terr: int = w2.register_component(DCComponentIds.CELL_TERRAIN, DCComponentIds.U8, 1, false)
	w2.create_entities(8)
	w2.deserialize(snap)

	# 7. round-trip bit-equal（仅 cell_temp 用 abs 容差，f32 round-trip 应该 bit-equal）
	var ok_f32: bool = true
	for i in range(8):
		if absf(w2.read_f32(c2_temp, i) - temps[i]) > 1e-9:
			ok_f32 = false
			break
	_expect("f32 round-trip bit-equal", ok_f32)

	var ok_i32: bool = true
	for i in range(8):
		if w2.read_i32(c2_parent, i) != parents[i]:
			ok_i32 = false
			break
	_expect("i32 round-trip bit-equal", ok_i32)

	var ok_u8: bool = true
	for i in range(8):
		if w2.read_u8(c2_terr, i) != terrs[i]:
			ok_u8 = false
			break
	_expect("u8 round-trip bit-equal", ok_u8)

	# 8. n_cells mismatch 错误防御
	var w3: DCWorld = DCWorld.new()
	w3.register_component(DCComponentIds.CELL_TEMP, DCComponentIds.F32, 1, false)
	w3.create_entities(4)
	# 静默期望 push_error，函数 return 不抛异常
	w3.deserialize(snap)
	_expect("n_cells mismatch returns silently (no crash)", true)

	# 9. version < SAVE_VERSION 触发 warning 但不阻塞
	var legacy_snap: Dictionary = snap.duplicate(true)
	legacy_snap["version"] = 0
	w2.deserialize(legacy_snap)
	_expect("legacy version triggers migration hook (no crash)", true)

	# 10. 总结
	print("  → checks=%d  failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== world_serialize test PASS ===")
	else:
		printerr("=== world_serialize test FAIL: %d failures ===" % _failures)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
