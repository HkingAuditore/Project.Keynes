extends RefCounted
## 模板：vN → vN+1 schema migration（PR-4.2，参考 master 手册 §6.4）。
##
## 用法：
##   1. 复制本文件为 v1_to_v2.gd / v2_to_v3.gd 等具体版本号文件
##   2. 改文件名，删掉 "_template" 前缀
##   3. 把 apply() 里的 TODO 替换为本 PR 的迁移逻辑
##   4. 在 _schema_migrations.gd 的 _MIGRATIONS 数组追加 preload
##   5. 在 tests/schema_migration_test.gd 加一个验收 case
##
## 三种基础操作 helper：
##   - DCMigrationOps.add_field(d, cpp_name, dtype, default)
##   - DCMigrationOps.rename_field(d, old_name, new_name)
##   - DCMigrationOps.delete_field(d, cpp_name)
##
## 复合操作：
##   - DCMigrationOps.change_dtype(d, cpp_name, new_dtype, default)
##
## d 结构请参考 world.gd::serialize() 输出。

static func apply(d: Dictionary) -> Dictionary:
	# 示例：v1 → v2 加一个 cell.example_new_field（F32, 默认 0.5）
	# DCMigrationOps.add_field(d, "cell_example_new_field", DCComponentIds.F32, 0.5)
	#
	# 示例：v2 → v3 把 cell.foo 改名为 cell.foo_v2
	# DCMigrationOps.rename_field(d, "cell_foo", "cell_foo_v2")
	#
	# 示例：v3 → v4 删除已废弃的 cell.deprecated_field
	# DCMigrationOps.delete_field(d, "cell_deprecated_field")
	return d
