# Schema Migrations

> Phase 4.2 / dots-phase4-followup.md §4.2

DCWorld 序列化 dict 跨版本迁移的中央目录。每个 `vN_to_vN_plus_1.gd` 把 dict 从 vN 迁移到 vN+1。

## 当前状态

`DCWorld.SAVE_VERSION = 1`（首版），无前置 migration。

## SOP

加新 migration（4 步）：

1. 把 [`world.gd::SAVE_VERSION`](../../scripts/data_core/world.gd) 升 1（例如 1 → 2）；
2. 在本目录新增 `vN_to_vN_plus_1.gd`，参考 [`_schema_migrations.gd`](./_schema_migrations.gd) 顶部注释的 SOP；
3. 在 `_schema_migrations.gd::_MIGRATIONS` 数组追加该 script 的 preload；
4. 在 `tests/schema_migration_test.gd` 加单测。

## 三种迁移类型

参见 [`_schema_migrations.gd`](./_schema_migrations.gd) 顶部注释。

## 历史

| Version | Migration | 说明 |
|---|---|---|
| v1 | - | 首版（2026-05），无 migration 负担 |
