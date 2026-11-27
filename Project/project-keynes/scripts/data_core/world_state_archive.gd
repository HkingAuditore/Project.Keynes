extends RefCounted


## 把 DCWorld 当前的全部 SoA 状态打包成 Dictionary，供存档系统持久化到磁盘。
##
## 输出结构：
##   {
##     "version": int (= SAVE_VERSION),
##     "n_cells": int,
##     "n_fronts": int,
##     "cells": Dictionary { cpp_name: PackedArray },  # 生产字段（demo 跳过）
##     "fronts": Dictionary,                            # Phase 4.1 PR-4.1.2 后扩展
##   }
##
## 注意：返回的 PackedArray 是 view_*() 的拷贝（CoW，下次 mutation 各自独立）。
##       caller 可以直接 var_to_bytes 写入文件。
static func serialize(owner: Variant) -> Dictionary:
	var out: Dictionary = {
		"version": owner.SAVE_VERSION,
		"n_cells": owner._entity_count if owner._entity_count > 0 else (owner._slots[0].arr_f32.size() if owner._slots.size() > 0 else 0),
		"n_fronts": 0,
		"cells": owner._serialize_cells_dict(),
		"fronts": owner._serialize_fronts_dict(),
	}
	return out


## 把序列化的 Dictionary 反向写回 DCWorld 的 SoA。
##
## 流程：
##   1. 读 version；若低于 SAVE_VERSION，调用 schema migration（Phase 4.2 实装）
##   2. 验证 n_cells 与当前 _entity_count 一致（否则 push_error）
##   3. 遍历 CELL_SCHEMA，按 cpp_name 从 d["cells"] 读 PackedArray，写入对应 _slots
##   4. fronts 反序列化（Phase 4.1 PR-4.1.2 后实装）
##
## 失败时不抛异常，仅 push_error；caller 应自行检查游戏状态。
static func deserialize(owner: Variant, d: Dictionary) -> void:
	var v: int = int(d.get("version", 0))
	if v < owner.SAVE_VERSION:
		# Phase 4.2 schema migration 钩子（暂未实装）：
		# d = DCSchemaMigrations.migrate(d, v, SAVE_VERSION)
		push_warning("[DCWorld] deserialize: save version=%d < current=%d; schema migration not yet implemented (Phase 4.2)" % [v, owner.SAVE_VERSION])
	var n_save: int = int(d.get("n_cells", -1))
	if n_save < 0:
		push_error("[DCWorld] deserialize: n_cells missing")
		return
	if n_save != owner._entity_count:
		push_error("[DCWorld] deserialize: n_cells mismatch (save=%d, current=%d) — re-bind to matching MapData first" % [n_save, owner._entity_count])
		return
	owner._deserialize_cells_dict(d.get("cells", {}))
	owner._deserialize_fronts_dict(d.get("fronts", {}))
