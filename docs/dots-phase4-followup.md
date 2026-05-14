> **DEPRECATED 2026-05-14**：本文档已被
> [`dots-master-execution-handbook.md`](./dots-master-execution-handbook.md) §5 + §8 替代。
> Phase 4 阶段 III 序列化 + soak 基建（PR-4.1 ~ PR-4.4）现集中在 master 手册。
> 本文档保留以便 git history 追溯，**不再维护**。

# Phase 4 — Stage III 序列化 + soak-test 基建 Follow-up 设计

> 状态：Phase 2/3 大半完成后启动；约 6 个 PR / 4 周
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §III / [`dots-component-schema.md`](./dots-component-schema.md)
> 创建：2026-05-14

---

## 0. Phase 4 启动前置

- [ ] Phase 2.3 HexCell facade 完成（数据所有权 100% 在 SoA）
- [ ] CELL_SCHEMA + FRONTS_SCHEMA 单一源 ✅（Phase 1.2 已就位）
- [ ] feature_flags.gd 中央化 ✅（已就位）

---

## Phase 4.1 — DCWorld serialize / deserialize（W23-W24，~3 PR）

### API 设计

```gdscript
# scripts/data_core/world.gd 末尾追加：

const SAVE_VERSION: int = 1

func serialize() -> Dictionary:
    var out: Dictionary = {
        "version": SAVE_VERSION,
        "n_cells": cell_count(),
        "n_fronts": _query_pool_used(DCComponentIds.POOL_WEATHER_FRONTS),
        "cells": _serialize_cells(),
        "fronts": _serialize_fronts(),
    }
    return out

func deserialize(d: Dictionary) -> void:
    var v: int = int(d.get("version", 0))
    if v < SAVE_VERSION:
        # schema migration 钩子（Phase 4.2）
        d = DCSchemaMigrations.migrate(d, v, SAVE_VERSION)
    _deserialize_cells(d.get("cells", {}))
    _deserialize_fronts(d.get("fronts", {}))

func _serialize_cells() -> Dictionary:
    # 按 component_schema.gd CELL_SCHEMA 自动遍历 38 entries
    # 跳过 demo entries（demo=true 的 entry）
    var out: Dictionary = {}
    for e in DCComponentSchema.entries_production():
        var cid: int = component_id(e.cpp_name)
        if cid < 0: continue
        match int(e.dtype):
            DCComponentIds.F32:
                out[String(e.cpp_name)] = view_f32(cid)
            DCComponentIds.I32:
                out[String(e.cpp_name)] = view_i32(cid)
            DCComponentIds.U8:
                out[String(e.cpp_name)] = view_u8(cid)
    return out

func _serialize_fronts() -> Dictionary:
    # 按 fronts_schema.gd FRONTS_SCHEMA 遍历
    # 当前阶段（FRONTS_SCHEMA 是预备）：caller 通过 WeatherFront.pack_into_dict
    # 拿到 batch dict，本方法接收并存储
    return {} # 占位
```

### PR 序列

- **PR-4.1.1 API + 版本号**：增加 SAVE_VERSION 常量 + serialize/deserialize 骨架
- **PR-4.1.2 cell + front 全字段 round-trip**：实装 _serialize_cells / _deserialize_cells；fronts 通过 WeatherFront.pack_into_dict 接入
- **PR-4.1.3 10 周年存档 round-trip bit-equal 验收**：跑一个游戏到 W520（10 周年），save → kill → load → 继续跑 1 周，bit-equal 校对

### 验收

- save 文件大小 < 5 MB（24×100 cells + 16 fronts × 23 字段）
- save / load 各 < 100ms
- round-trip bit-equal：load 后所有 SoA 数值 byte-equal

---

## Phase 4.2 — schema migration 钩子（W25，~2 PR）

### 目录设计

```
tools/schema_migrations/
├── _schema_migrations.gd        # 中央 dispatcher
├── v0_to_v1.gd                  # 示例：加 cell.demo.thermal_gradient
└── README.md                    # SOP 与历史记录
```

### API

```gdscript
# tools/schema_migrations/_schema_migrations.gd
class_name DCSchemaMigrations

const _MIGRATIONS: Array = [
    preload("res://tools/schema_migrations/v0_to_v1.gd"),
    # 后续版本追加
]

static func migrate(d: Dictionary, from_v: int, to_v: int) -> Dictionary:
    while from_v < to_v:
        var m = _MIGRATIONS[from_v]  # idx = from_v
        d = m.apply(d)
        from_v += 1
    return d
```

### 单个 migration 模板

```gdscript
# tools/schema_migrations/v0_to_v1.gd
class_name SchemaMigrationV0ToV1
extends RefCounted

# v0 → v1：加 cell.demo.thermal_gradient（默认 0.0 全图）
static func apply(d: Dictionary) -> Dictionary:
    var cells: Dictionary = d.get("cells", {})
    var n: int = int(d.get("n_cells", 0))
    if not cells.has("cell_demo_thermal_gradient"):
        var arr: PackedFloat32Array = PackedFloat32Array()
        arr.resize(n)
        cells["cell_demo_thermal_gradient"] = arr
    d["cells"] = cells
    d["version"] = 1
    return d
```

### 三种迁移类型支持

1. **加新字段**：旧 dict 缺该 key → 填默认值
2. **重命名**：把 dict[old_key] 移到 dict[new_key]
3. **删除字段**：dict.erase(old_key)

### PR 序列

- **PR-4.2.1**：tools/schema_migrations/ 目录 + dispatcher + 1 个 example migration
- **PR-4.2.2**：3 种类型单测（tests/schema_migration_test.gd）

---

## Phase 4.3 — soak-test 夹具（W25，~2 PR）

### 当前 baseline

[`tools/migration_harness/template_module_test.gd`](../Project/project-keynes/tools/migration_harness/template_module_test.gd) 已是 soak-test 模板，但只覆盖单 module。

### 目标 fixture

```
tools/soak_harness/
├── soak_runner.gd            # 主入口
├── random_map_generator.gd   # 用 cfg seed 生成 random map
├── soak_assertions.gd        # 1000-day soak 断言模板
└── ab_diff.gd                # DOTS-A vs DOTS-B 对照工具
```

### 调用 SOP

```gdscript
# tests/soak_test_full_world.gd
func test_full_soak() -> void:
    var seed: int = 12345
    var dots_a_result = SoakRunner.run({
        "seed": seed, "days": 1000,
        "flags": { "use_gdext_*": false, "use_world_view_adapter": true },
    })
    var dots_b_result = SoakRunner.run({
        "seed": seed, "days": 1000,
        "flags": { "use_gdext_*": true, "use_world_view_adapter": true },
    })
    var diff = AbDiff.compare(dots_a_result, dots_b_result, tol_f32=1e-5)
    assert_true(diff.bit_equal_pct > 0.9999, "DOTS-A vs DOTS-B 偏差 %.4f%% > 0.01%%" % (1.0 - diff.bit_equal_pct))
```

### 包含子任务

- **save-load round-trip**：1000-day 中途随机 save / load，对比 load 后继续跑 100-day 与不 load 一致
- **DOTS-A vs DOTS-B 对照**：6 个 use_gdext_* flag 的 ON/OFF 对比
- **multi-seed 稳定性**：seed=[1, 2, 3, 5, 8, 13, 21] × days=200 的 mini soak

---

## Phase 4.4 — FeatureFlag hot-reload（W26，~1 PR）

### 现状

[`feature_flags.gd::toggle`](../Project/project-keynes/scripts/data_core/feature_flags.gd) 当前修改 ClimateProfile 但需要重启游戏才生效（因为 DCWorld.bind_map_data 仅启动期跑一次）。

### 目标

editor 内或 dev console 改 flag → 自动 unbind/rebind → 立即生效。

### API

```gdscript
# scripts/data_core/feature_flags.gd 顶部新增：
signal flag_changed(name: StringName, new_value)

func toggle(name: StringName) -> void:
    var old = get_flag_value(name)
    var new = not bool(old)
    set_flag_value(name, new)
    flag_changed.emit(name, new)

# scripts/data_core/world.gd 监听：
func _on_flag_changed(name: StringName, new_value) -> void:
    # 仅对影响 bind 的 flag 反应（use_data_core / use_world_view_adapter / 个别 schema 字段）
    var bind_critical_flags: Array[StringName] = [
        &"use_data_core",
        &"use_world_view_adapter",
        &"demo_thermal_gradient_enabled",
    ]
    if name in bind_critical_flags:
        unbind_map_data()
        bind_map_data(_last_map_data)
        print("[FeatureFlag] hot-reload: %s = %s (re-bind done)" % [name, str(new_value)])
```

### PR 序列

- **PR-4.4.1**：feature_flags.gd 加 flag_changed signal + DCWorld._on_flag_changed handler；handler 在 bind_map_data 内自动 connect
- **PR-4.4.2**：完成后 [`dots-framework-status.md`](./dots-framework-status.md) §1 速读图所有项标 ✅，标记**完全 DOTS 化达成**

### 验收

- editor 改 flag 后无需重启游戏
- 切回旧 flag 后行为无 hysteresis（必须 byte-equal）

---

## Phase 4 总结

完成后 [`dots-framework-status.md`](./dots-framework-status.md) §1 速读图：

```
Data Layer       ✅✅✅
Read Side        ✅✅
System Layer     ✅✅✅
Engineering      ✅✅✅
```

**完全 DOTS 化达成**。阶段 IV（SIMD / chunk_remap / D-async）按 charter §3.1 / §3.2 条件触发，不主动启动。

---

**END.**
