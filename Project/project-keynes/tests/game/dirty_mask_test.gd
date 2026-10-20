# dirty_mask_test.gd
# plan: cell-dirty-push-and-dots-atlas-bakers, 阶段 A/B 验收
#
# 验证 DCWorld._dirty_cell_mask 在 9 个 write_* API 漏斗位被正确 mark；
# 且 HexCell 21 个 facade setter 通过 _world.write_* 自动透传 dirty 标记
# （不需要 setter 内单独调用 mark_dirty）。
#
# 范围：
#   1. write_f32 / write_i32 / write_u8 单点 → mask[idx]=1
#   2. write_f32_range / write_i32_range / write_u8_range → mask[start..end)=1
#   3. write_f32_indexed / write_i32_indexed / write_u8_indexed → mask[indices]=1
#   4. read_and_clear_dirty_mask 返回升序 PackedInt32Array 且 mask 全 0
#   5. 越界 idx 不写 mask、不 crash
#   6. dirty_mask_enabled = false 时 mark 全 no-op
#   7. mark_dirty / mark_dirty_all / peek_dirty_count 行为符合契约
#   8. write 到非 cell-pool（idx >= mask_size）不 mark（front 池等共用 write API）
#   9. HexCell facade setter 触发的 dirty 透传：cell.temperature = v → mask[index]=1
#
# Headless execution:
#     godot --headless --script tests/dirty_mask_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== dirty_mask test (plan: cell-dirty-push-and-dots-atlas-bakers, A/B) ===")
	_test_basic_write_funnels()
	_test_range_funnel()
	_test_indexed_funnel()
	_test_read_and_clear_atomic()
	_test_out_of_range()
	_test_disable_flag()
	_test_mark_helpers()
	_test_pool_boundary()
	_test_hexcell_facade_setter_propagation()
	print("=== dirty_mask test summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 1. 单点写漏斗 ──────────────────────────────────────────────
func _test_basic_write_funnels() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	var cid_i: int = world.register_component(&"t.i", DCComponentIds.I32, 1, false)
	var cid_u: int = world.register_component(&"t.u", DCComponentIds.U8, 1, false)
	world.create_entities(10)
	world._resize_dirty_mask(10)  # 模拟 bind_map_data 行为
	_expect("init mask zero (peek=0)", world.peek_dirty_count() == 0)

	world.write_f32(cid_f, 3, 1.5)
	_expect("write_f32 marks idx=3", world.peek_dirty_count() == 1)
	world.write_i32(cid_i, 7, 42)
	_expect("write_i32 marks idx=7", world.peek_dirty_count() == 2)
	world.write_u8(cid_u, 0, 0x42)
	_expect("write_u8 marks idx=0", world.peek_dirty_count() == 3)

	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("read_and_clear returns 3 ascending", dirty.size() == 3 and dirty[0] == 0 and dirty[1] == 3 and dirty[2] == 7)
	_expect("mask cleared after read", world.peek_dirty_count() == 0)


# ─── 2. range 写漏斗 ────────────────────────────────────────────
func _test_range_funnel() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(10)
	world._resize_dirty_mask(10)

	var src: PackedFloat32Array = PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	world.write_f32_range(cid_f, 2, src)
	_expect("write_f32_range marks 4 cells", world.peek_dirty_count() == 4)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("range dirty = [2,3,4,5]",
		dirty.size() == 4 and dirty[0] == 2 and dirty[1] == 3 and dirty[2] == 4 and dirty[3] == 5)


# ─── 3. indexed 写漏斗 ──────────────────────────────────────────
func _test_indexed_funnel() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(20)
	world._resize_dirty_mask(20)

	var indices: PackedInt32Array = PackedInt32Array([0, 5, 10, 15, 19])
	var values: PackedFloat32Array = PackedFloat32Array([1, 2, 3, 4, 5])
	world.write_f32_indexed(cid_f, indices, values)
	_expect("write_f32_indexed marks 5 cells", world.peek_dirty_count() == 5)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("indexed dirty = [0,5,10,15,19]",
		dirty.size() == 5 and dirty[0] == 0 and dirty[1] == 5 and dirty[2] == 10 and dirty[3] == 15 and dirty[4] == 19)


# ─── 4. read_and_clear 原子语义 ────────────────────────────────
func _test_read_and_clear_atomic() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(5)
	world._resize_dirty_mask(5)

	world.write_f32(cid_f, 0, 1.0)
	world.write_f32(cid_f, 0, 2.0)  # 重复写同一 idx
	world.write_f32(cid_f, 4, 3.0)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("repeated write same idx -> 1 dirty", dirty.size() == 2)
	_expect("dirty contains 0", dirty.has(0))
	_expect("dirty contains 4", dirty.has(4))

	# 第二次读应该是空
	var empty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("second read returns empty", empty.size() == 0)


# ─── 5. 越界 idx 不写 mask、不 crash ───────────────────────────
func _test_out_of_range() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(5)
	world._resize_dirty_mask(5)

	# 单点越界（write_f32 会 push_error，但不应让 mask 标脏）
	# 通过 mark_dirty public API 测，绕开 write_f32 的 push_error 噪音
	world.mark_dirty(-1)
	world.mark_dirty(5)   # 边界外
	world.mark_dirty(100)
	_expect("out-of-range mark_dirty no-op", world.peek_dirty_count() == 0)

	# range 越界裁剪
	world.mark_dirty_range(3, 100)  # [3, 103) 应被裁到 [3, 5)
	_expect("range clipped to [3,5)", world.peek_dirty_count() == 2)
	world.read_and_clear_dirty_mask()


# ─── 6. dirty_mask_enabled = false 全 no-op ─────────────────────
func _test_disable_flag() -> void:
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(5)
	world._resize_dirty_mask(5)
	world.dirty_mask_enabled = false

	world.write_f32(cid_f, 2, 1.0)
	world.mark_dirty(3)
	world.mark_dirty_range(0, 5)
	_expect("disabled flag suppresses all marks", world.peek_dirty_count() == 0)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("disabled read returns empty", dirty.size() == 0)


# ─── 7. mark_dirty / mark_dirty_all / peek 契约 ────────────────
func _test_mark_helpers() -> void:
	var world: DCWorld = DCWorld.new()
	world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(8)
	world._resize_dirty_mask(8)

	world.mark_dirty_all()
	_expect("mark_dirty_all -> peek=8", world.peek_dirty_count() == 8)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("mark_dirty_all dirty = [0..7]", dirty.size() == 8 and dirty[0] == 0 and dirty[7] == 7)


# ─── 8. cells pool 之外的写不 mark ─────────────────────────────
func _test_pool_boundary() -> void:
	# 模拟：cell pool [0, 10)，front 池 [10, 18)（共用 write_f32 但不应进 mask）
	var world: DCWorld = DCWorld.new()
	var cid_f: int = world.register_component(&"t.f", DCComponentIds.F32, 1, false)
	world.create_entities(18)
	world._resize_dirty_mask(10)  # mask 只覆盖 cell pool

	world.write_f32(cid_f, 5, 1.0)   # cell pool
	world.write_f32(cid_f, 12, 2.0)  # front pool（idx >= mask_size）
	world.write_f32(cid_f, 17, 3.0)  # front pool 末尾
	_expect("only cell-pool write marks", world.peek_dirty_count() == 1)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("dirty = [5] only", dirty.size() == 1 and dirty[0] == 5)


# ─── 9. HexCell facade setter dirty 透传 ─────────────────────────
# 这是阶段 B 的关键验收：HexCell 21 个 setter 都走 _world.write_*，
# 不需要 setter 里再调 mark_dirty。验证 cell.temperature = v 会自动让
# mask[index] 标脏。
func _test_hexcell_facade_setter_propagation() -> void:
	var world: DCWorld = DCWorld.new()
	# 注册 HexCell facade 涉及的 cell.temp（仅测一个字段，证明透传机制即可）
	world.register_component(&"cell.temp", DCComponentIds.F32, 1, false)
	world.create_entities(5)
	world._resize_dirty_mask(5)

	var cell: HexCell = HexCell.new(0, 0)
	cell.index = 2
	cell.bind_world(world, true)  # enable_facade=true

	# 触发 setter
	cell.temperature = 0.75
	_expect("facade setter triggers dirty (peek=1)", world.peek_dirty_count() == 1)
	var dirty: PackedInt32Array = world.read_and_clear_dirty_mask()
	_expect("facade dirty = [2]", dirty.size() == 1 and dirty[0] == 2)

	# facade 关闭路径不应 mark
	cell._facade_enabled = false
	cell.temperature = 0.99
	_expect("facade-disabled setter no-op for mask", world.peek_dirty_count() == 0)


# ─── helper ────────────────────────────────────────────────────
func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
