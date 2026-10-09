extends RefCounted
class_name DCMigrationOps

## PR-4.2 — Schema Migration 三种通用操作的 helper（dots-master-execution-handbook §6）。
##
## 每条具体 vN_to_vN_plus_1.gd 在 apply(d) 内组合调用本 helper，避免重复写
## "查 cells dict 里有没有这个 key、resize PackedArray、填默认值" 的样板代码。
##
## 三种基础迁移操作（与 component_schema.gd 的 add / rename / delete 一一对应）：
##   1. add_field(d, cpp_name, dtype, default_value)
##   2. rename_field(d, old_cpp_name, new_cpp_name)
##   3. delete_field(d, cpp_name)
##
## d 的结构（参见 world.gd::serialize() / deserialize()）：
##   {
##     "version": int,
##     "n_cells": int,
##     "cells": Dictionary { cpp_name: PackedArray },
##     "fronts": Dictionary,
##   }
##
## dtype：与 DCComponentIds.F32 / I32 / U8 一致（int 编码）。
## default_value：传 float / int 标量；helper 内自动按 n_cells 把 PackedArray
## resize 并 fill。

# ─── 基础工具 ───────────────────────────────────────────────────────


static func _ensure_cells(d: Dictionary) -> Dictionary:
	if not d.has("cells"):
		d["cells"] = {}
	return d["cells"]


static func _n_cells(d: Dictionary) -> int:
	return int(d.get("n_cells", 0))


# ─── 1. ADD：加新字段，默认值填充 ───────────────────────────────────


## 给 dict 添加一个新字段。如果该字段已存在 → no-op（幂等）。
##
## dtype: 与 DCComponentIds.F32/I32/U8 对齐（0/1/2/3 等）。
## 当前 helper 仅支持 F32/I32/U8 三种通用 dtype。VEC2_F32/VEC3_F32 走拆轴，
## 由 caller 调两次/三次 add_field（每个轴一个 cpp_name）。
##
## 返回 modified d（与传入是同一引用，便于链式调用）。
static func add_field(d: Dictionary, cpp_name: String, dtype: int, default_value = 0.0) -> Dictionary:
	var cells: Dictionary = _ensure_cells(d)
	if cells.has(cpp_name):
		return d  # 幂等：已存在视为成功
	var n: int = _n_cells(d)
	if n <= 0:
		push_error("[DCMigrationOps] add_field(%s): n_cells=%d invalid" % [cpp_name, n])
		return d
	match dtype:
		DCComponentIds.F32:
			var arr_f: PackedFloat32Array = PackedFloat32Array()
			arr_f.resize(n)
			arr_f.fill(float(default_value))
			cells[cpp_name] = arr_f
		DCComponentIds.I32:
			var arr_i: PackedInt32Array = PackedInt32Array()
			arr_i.resize(n)
			arr_i.fill(int(default_value))
			cells[cpp_name] = arr_i
		DCComponentIds.U8:
			var arr_u: PackedByteArray = PackedByteArray()
			arr_u.resize(n)
			arr_u.fill(int(default_value) & 0xFF)
			cells[cpp_name] = arr_u
		_:
			push_error("[DCMigrationOps] add_field(%s): unsupported dtype=%d (use F32/I32/U8)" % [cpp_name, dtype])
	return d


# ─── 2. RENAME：字段改名（保留数据）────────────────────────────────


## 把 dict[old_cpp_name] 搬到 dict[new_cpp_name]，不改数据。
##
## 注意：同时需要在 component_schema.gd 改 cpp_name + MapData _arr 字段名 +
##       所有 hot path 引用（grep 一次）。本 helper 仅负责存档侧 key rename。
##
## old key 不存在 → no-op（幂等）。
## new key 已存在 → push_warning 并保留 new key（不覆盖）。
##
## 返回 modified d。
static func rename_field(d: Dictionary, old_cpp_name: String, new_cpp_name: String) -> Dictionary:
	var cells: Dictionary = _ensure_cells(d)
	if not cells.has(old_cpp_name):
		return d  # 幂等：旧 key 已不存在视为已迁移
	if cells.has(new_cpp_name):
		push_warning("[DCMigrationOps] rename_field(%s → %s): new key already exists; old data discarded"\
			% [old_cpp_name, new_cpp_name])
		cells.erase(old_cpp_name)
		return d
	cells[new_cpp_name] = cells[old_cpp_name]
	cells.erase(old_cpp_name)
	return d


# ─── 3. DELETE：删除字段 ────────────────────────────────────────────


## 把 dict[cpp_name] 删除（视为字段下线）。
##
## 不存在 → no-op（幂等）。
##
## 注意：caller 应在调用本 helper 前 ripgrep 确保业务路径已不读该字段，
## 否则升级后存档读取会触发 push_error。
##
## 返回 modified d。
static func delete_field(d: Dictionary, cpp_name: String) -> Dictionary:
	var cells: Dictionary = _ensure_cells(d)
	if cells.has(cpp_name):
		cells.erase(cpp_name)
	return d


# ─── 4. 复合：同时 add + delete（适用于 dtype 改变场景）─────────────


## 用例：F32 字段改为 I32（不应在 production 出现，但单测/紧急场景需要）。
## 流程 = delete 旧 dtype 字段 + add 新 dtype 字段（默认值填充）。
static func change_dtype(d: Dictionary, cpp_name: String, new_dtype: int, default_value = 0.0) -> Dictionary:
	delete_field(d, cpp_name)
	add_field(d, cpp_name, new_dtype, default_value)
	return d
