# world_write_indexed_test.gd
# PR-2.0 — 批量索引写 API 自检。
#
# 验证：
#   1. write_f32_indexed / write_i32_indexed / write_u8_indexed 基本写入正确
#   2. 越界 idx 静默跳过（不 push_error，与单点 write_f32 不同；批量场景静默跳过）
#   3. indices.size() 与 values.size() 不一致时取 min 截断
#   4. dtype 不匹配时整调用 return（push_error 一次）
#   5. 空数组调用安全（不 crash）
#
# Headless execution:
#     godot --headless --script tests/world_write_indexed_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== world_write_indexed test (PR-2.0) ===")
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(DCComponentIds.CELL_TEMP, DCComponentIds.F32, 1, false)
	var cid_i: int = world.register_component(DCComponentIds.CELL_LANDFORM, DCComponentIds.I32, 1, false)
	var cid_u: int = world.register_component(DCComponentIds.CELL_TERRAIN, DCComponentIds.U8, 1, false)
	world.create_entities(10)
	_expect("CELL_TEMP F32 registered", cid_f >= 0)
	_expect("CELL_LANDFORM I32 registered", cid_i >= 0)
	_expect("CELL_TERRAIN U8 registered", cid_u >= 0)

	# 1. write_f32_indexed 基本写入
	var indices_f: PackedInt32Array = PackedInt32Array([0, 3, 5, 9])
	var values_f: PackedFloat32Array = PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	world.write_f32_indexed(cid_f, indices_f, values_f)
	_expect("f32 idx=0 -> 1.0", absf(world.read_f32(cid_f, 0) - 1.0) < 1e-6)
	_expect("f32 idx=3 -> 2.0", absf(world.read_f32(cid_f, 3) - 2.0) < 1e-6)
	_expect("f32 idx=5 -> 3.0", absf(world.read_f32(cid_f, 5) - 3.0) < 1e-6)
	_expect("f32 idx=9 -> 4.0", absf(world.read_f32(cid_f, 9) - 4.0) < 1e-6)
	_expect("f32 idx=1 untouched (default 0.0)", absf(world.read_f32(cid_f, 1)) < 1e-6)

	# 2. write_i32_indexed 基本写入
	var indices_i: PackedInt32Array = PackedInt32Array([1, 4, 7])
	var values_i: PackedInt32Array = PackedInt32Array([10, 20, 30])
	world.write_i32_indexed(cid_i, indices_i, values_i)
	_expect("i32 idx=1 -> 10", world.read_i32(cid_i, 1) == 10)
	_expect("i32 idx=4 -> 20", world.read_i32(cid_i, 4) == 20)
	_expect("i32 idx=7 -> 30", world.read_i32(cid_i, 7) == 30)

	# 3. write_u8_indexed 基本写入 + 0xFF 截断
	var indices_u: PackedInt32Array = PackedInt32Array([2, 6])
	var values_u: PackedByteArray = PackedByteArray([0x42, 0xAB])
	world.write_u8_indexed(cid_u, indices_u, values_u)
	_expect("u8 idx=2 -> 0x42", world.read_u8(cid_u, 2) == 0x42)
	_expect("u8 idx=6 -> 0xAB", world.read_u8(cid_u, 6) == 0xAB)

	# 4. 越界 idx 静默跳过（不 push_error）
	var oob_idx: PackedInt32Array = PackedInt32Array([100, 5, -1])
	var oob_val: PackedFloat32Array = PackedFloat32Array([99.0, 7.0, 88.0])
	world.write_f32_indexed(cid_f, oob_idx, oob_val)
	_expect("oob idx=100 silent skip", absf(world.read_f32(cid_f, 5) - 7.0) < 1e-6)
	_expect("oob idx=-1 silent skip (idx=5 still 7.0)", absf(world.read_f32(cid_f, 5) - 7.0) < 1e-6)

	# 5. indices.size != values.size 取 min 截断
	var idx_short: PackedInt32Array = PackedInt32Array([0, 1, 2])
	var val_long: PackedFloat32Array = PackedFloat32Array([10.0, 20.0, 30.0, 40.0, 50.0])
	world.write_f32_indexed(cid_f, idx_short, val_long)
	_expect("size mismatch idx=0 -> 10.0", absf(world.read_f32(cid_f, 0) - 10.0) < 1e-6)
	_expect("size mismatch idx=2 -> 30.0", absf(world.read_f32(cid_f, 2) - 30.0) < 1e-6)
	# idx=3 应保持 2.0（来自第一次写入，未被本次覆盖）
	_expect("size mismatch idx=3 untouched (still 2.0 from step 1)", absf(world.read_f32(cid_f, 3) - 2.0) < 1e-6)

	# 6. 空数组调用安全
	world.write_f32_indexed(cid_f, PackedInt32Array(), PackedFloat32Array())
	_expect("empty arrays no crash", true)

	# 7. dtype 不匹配（用 i32 cid 调 f32 API） — 应 push_error 后 return，不写
	# 注：SceneTree 测试中 push_error 不会让 expect 失败，但写入应被拒绝
	world.write_f32_indexed(cid_i, indices_i, PackedFloat32Array([99.0, 99.0, 99.0]))
	_expect("dtype mismatch: i32 cid 不被 f32 API 改写 (idx=1 仍为 10)", world.read_i32(cid_i, 1) == 10)

	print("=== world_write_indexed: %d/%d checks PASS ===" % [_checks - _failures, _checks])


func _expect(name: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL: %s" % name)
	else:
		print("PASS: %s" % name)
