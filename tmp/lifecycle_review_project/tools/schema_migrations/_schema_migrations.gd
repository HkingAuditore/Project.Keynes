extends RefCounted
class_name DCSchemaMigrations

## Phase 4.2 — Schema Migration 中央 Dispatcher（dots-phase4-followup.md §4.2）
##
## 当前实现：**骨架阶段** —— 数组结构 + dispatcher 已就位，具体 migration 类
## 等 SAVE_VERSION 真正升到 v2+ 时再追加（首版 SAVE_VERSION=1，没有迁移负担）。
##
## ─── 加新 migration 的 SOP（4 步）─────────────────────────────────────
##
##   1. 把 [`world.gd::SAVE_VERSION`](../data_core/world.gd) 升 1（例如 1 → 2）；
##   2. 在本目录新增 `vN_to_vN_plus_1.gd`，extends RefCounted，实装 static
##      `apply(d: Dictionary) -> Dictionary` 方法；
##   3. 在下方 `_MIGRATIONS` 数组追加该 script 的 preload；
##   4. 在 `tests/schema_migration_test.gd` 加单测：
##      - 构造一个旧版本 dict
##      - 调 migrate() 升级
##      - 验证新字段存在且默认值正确
##
## ─── 三种迁移类型 ────────────────────────────────────────────────────
##
## 1. **加新字段**：旧 dict 缺该 key → 填默认值（PackedArray.resize + fill 0/false）
##    例：v0 → v1，cell.demo.thermal_gradient 默认全 0
##
## 2. **重命名字段**：把 dict[old_key] 移到 dict[new_key]
##    例：cell.temp_baseline → cell.temp_baseline_year（假设 v3 改名）
##    注意：同时要在 component_schema.gd 改 cpp_name；
##          MapData _arr 字段名也要改；
##          所有 hot path 引用要改（grep 一次）。
##
## 3. **删除字段**：dict.erase(old_key)
##    例：旧 cell.deprecated_field（假设 v4 删除）
##    注意：先 grep 确保业务路径已不读该字段，否则会运行时 push_error。

const _MIGRATIONS: Array = [
	# 当前版本 SAVE_VERSION=1，无前置 migration。
	# 后续追加格式：preload("res://tools/schema_migrations/v1_to_v2.gd"),
]


## 把 dict 从 from_v 迁移到 to_v；逐版本应用 _MIGRATIONS。
##
## 失败时返回原 dict + push_error（caller 应自行处理）。
static func migrate(d: Dictionary, from_v: int, to_v: int) -> Dictionary:
	if from_v == to_v:
		return d
	if from_v > to_v:
		push_error("[DCSchemaMigrations] cannot downgrade (from=%d to=%d)" % [from_v, to_v])
		return d
	var current_v: int = from_v
	var current_d: Dictionary = d
	while current_v < to_v:
		var idx: int = current_v  # _MIGRATIONS[N] 把 vN → vN+1
		if idx < 0 or idx >= _MIGRATIONS.size():
			push_error("[DCSchemaMigrations] missing migration v%d → v%d" % [current_v, current_v + 1])
			return current_d
		var script = _MIGRATIONS[idx]
		if script == null:
			push_error("[DCSchemaMigrations] null script at idx=%d" % idx)
			return current_d
		current_d = script.apply(current_d)
		current_v += 1
	return current_d


## 启动期 sanity check：可选调用，验证 _MIGRATIONS 数组连续完整。
static func validate() -> String:
	for i in range(_MIGRATIONS.size()):
		if _MIGRATIONS[i] == null:
			return "_MIGRATIONS[%d] is null" % i
		if not _MIGRATIONS[i].has_method("apply"):
			return "_MIGRATIONS[%d] missing static apply(d) -> Dictionary" % i
	return ""
