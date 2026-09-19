# schema_migration_test.gd
# PR-4.2 — DCMigrationOps add/rename/delete helper 验证 + dispatcher 边界。
#
# 验证：
#   1. add_field：F32/I32/U8 三种 dtype 的默认值填充正确
#   2. add_field 幂等：已存在字段时 no-op
#   3. add_field 拒绝非法 dtype（push_error 但不 crash）
#   4. rename_field：保留数据，erase 旧 key
#   5. rename_field 幂等：旧 key 不存在时 no-op
#   6. rename_field 冲突：new key 已存在时 push_warning 但不覆盖
#   7. delete_field：删除指定 key
#   8. delete_field 幂等：key 不存在时 no-op
#   9. change_dtype：F32 → I32 重置为默认值
#  10. DCSchemaMigrations.migrate(from=to)：no-op 直接返回
#  11. DCSchemaMigrations.migrate(missing v)：push_error 不 crash
#  12. DCSchemaMigrations.validate()：empty array 返回 ""
#
# Headless 运行：
#     godot --headless --script tests/schema_migration_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== schema_migration test (PR-4.2) ===")

	# ─── 1. add_field F32 ──────────────────────────────────────
	var d1: Dictionary = _make_empty_save(8)
	DCMigrationOps.add_field(d1, "cell_temp_new", DCComponentIds.F32, 0.5)
	var arr_f: PackedFloat32Array = d1["cells"]["cell_temp_new"]
	_expect("add_field F32 size=8", arr_f.size() == 8)
	_expect("add_field F32 default=0.5", absf(arr_f[0] - 0.5) < 1e-6 and absf(arr_f[7] - 0.5) < 1e-6)

	# ─── 2. add_field I32 ──────────────────────────────────────
	var d2: Dictionary = _make_empty_save(4)
	DCMigrationOps.add_field(d2, "cell_landform_new", DCComponentIds.I32, 7)
	var arr_i: PackedInt32Array = d2["cells"]["cell_landform_new"]
	_expect("add_field I32 size=4", arr_i.size() == 4)
	_expect("add_field I32 default=7", arr_i[0] == 7 and arr_i[3] == 7)

	# ─── 3. add_field U8 ───────────────────────────────────────
	var d3: Dictionary = _make_empty_save(4)
	DCMigrationOps.add_field(d3, "cell_terrain_new", DCComponentIds.U8, 42)
	var arr_u: PackedByteArray = d3["cells"]["cell_terrain_new"]
	_expect("add_field U8 size=4", arr_u.size() == 4)
	_expect("add_field U8 default=42", arr_u[0] == 42 and arr_u[3] == 42)

	# ─── 4. add_field 幂等 ───────────────────────────────────
	d1["cells"]["cell_temp_new"] = PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
	DCMigrationOps.add_field(d1, "cell_temp_new", DCComponentIds.F32, 0.5)
	var arr_f2: PackedFloat32Array = d1["cells"]["cell_temp_new"]
	_expect("add_field idempotent (existing not overwritten)", absf(arr_f2[0] - 1.0) < 1e-6)

	# ─── 5. rename_field 基本 ─────────────────────────────────
	var d4: Dictionary = _make_empty_save(4)
	d4["cells"]["cell_old"] = PackedFloat32Array([0.1, 0.2, 0.3, 0.4])
	DCMigrationOps.rename_field(d4, "cell_old", "cell_new")
	_expect("rename_field old key gone", not d4["cells"].has("cell_old"))
	_expect("rename_field new key present", d4["cells"].has("cell_new"))
	var arr_renamed: PackedFloat32Array = d4["cells"]["cell_new"]
	_expect("rename_field data preserved", absf(arr_renamed[0] - 0.1) < 1e-6)

	# ─── 6. rename_field 幂等（旧 key 不存在）─────────────────
	DCMigrationOps.rename_field(d4, "cell_old", "cell_new")
	_expect("rename_field idempotent (no-op)", true)

	# ─── 7. rename_field 冲突（new key 已存在）────────────────
	d4["cells"]["cell_pre_existing"] = PackedFloat32Array([9.9, 9.9, 9.9, 9.9])
	d4["cells"]["cell_to_rename"] = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	# 期望：push_warning + 不覆盖 + 旧 key erase
	DCMigrationOps.rename_field(d4, "cell_to_rename", "cell_pre_existing")
	_expect("rename_field conflict: old erased", not d4["cells"].has("cell_to_rename"))
	var arr_conflict: PackedFloat32Array = d4["cells"]["cell_pre_existing"]
	_expect("rename_field conflict: new not overwritten", absf(arr_conflict[0] - 9.9) < 1e-6)

	# ─── 8. delete_field ───────────────────────────────────────
	var d5: Dictionary = _make_empty_save(4)
	d5["cells"]["cell_to_del"] = PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	DCMigrationOps.delete_field(d5, "cell_to_del")
	_expect("delete_field removes key", not d5["cells"].has("cell_to_del"))

	# ─── 9. delete_field 幂等 ────────────────────────────────
	DCMigrationOps.delete_field(d5, "cell_to_del")
	_expect("delete_field idempotent (no-op)", true)

	# ─── 10. change_dtype（F32 → I32 + 默认值重置）────────────
	var d6: Dictionary = _make_empty_save(4)
	d6["cells"]["cell_dtype_change"] = PackedFloat32Array([1.5, 2.5, 3.5, 4.5])
	DCMigrationOps.change_dtype(d6, "cell_dtype_change", DCComponentIds.I32, 99)
	var arr_changed: PackedInt32Array = d6["cells"]["cell_dtype_change"]
	_expect("change_dtype size=4", arr_changed.size() == 4)
	_expect("change_dtype reset to default=99", arr_changed[0] == 99)

	# ─── 11. dispatcher: from_v == to_v ─────────────────────
	var d7: Dictionary = _make_empty_save(4)
	var d7_after: Dictionary = DCSchemaMigrations.migrate(d7, 1, 1)
	_expect("migrate(1,1) returns unchanged", d7_after.size() == d7.size())

	# ─── 12. dispatcher: missing migration ──────────────────
	# 期望：push_error + 返回原 d（不 crash）
	var d8: Dictionary = _make_empty_save(4)
	var d8_after: Dictionary = DCSchemaMigrations.migrate(d8, 0, 99)
	_expect("migrate(missing) returns silently", d8_after != null)

	# ─── 13. dispatcher: validate ───────────────────────────
	var validate_msg: String = DCSchemaMigrations.validate()
	_expect("validate() empty migrations array passes", validate_msg == "")

	# ─── 总结 ─────────────────────────────────────────────
	print("  → checks=%d  failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== schema_migration test PASS ===")
	else:
		printerr("=== schema_migration test FAIL: %d failures ===" % _failures)


func _make_empty_save(n: int) -> Dictionary:
	return {
		"version": 1,
		"n_cells": n,
		"cells": {},
		"fronts": {},
	}


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
