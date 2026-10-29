# M5-10 删除旧 v1 平面（§15.7 完成项）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7「删除旧 v1 平面」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **删除约 320 行死代码 + 3 个桥 + 2 个测试函数 + 1 个开发探针** |
| 验证 | 构建 exit 0；**21 / 22** fixture 通过（1 个为基线既有）；内核 **93 / 0** |

## 1. 决定性依据：平面从未在生产中运行

删除前读到的原注释（`world_ext_ideology.cpp`，已随代码删除）：

> Gated: see `_ideology_cell_plane_enabled`. **Off by default because the v1 table is
> not yet safe to apply** (stale generation, **double application with the per-cell
> instances**, coefficient semantics that differ from Modifier).

加上 M5-4 的实测：`_ideology_cell_programs` 的唯一生产者 `publish_ideology_cell_programs`
**GDScript 调用者只有一个测试**，`[B7] plane: builds=0`。

**它一直是关闭的、没有任何生产调用者。** 这与 §15.7 的「删除旧 v1 平面」完全对应。

## 2. 删除清单

| 项 | 位置 | 规模 |
|---|---|---|
| `build_cell_program_table` 定义 | `ideology_runtime.cpp` | **169 行** |
| 平面合并段 | `economy_runtime.cpp:7371-7441` | **74 行** |
| `set_ideology_cell_programs` | `economy_runtime.cpp` | 13 行 |
| 3 个桥实现 | `world_ext_ideology.cpp` | 62 行 |
| `_test_cell_program_table` | 测试 | ~76 行 |
| `_test_column_units` | 测试 | ~38 行 |
| `_probe_card_cell_plane.gd` | 开发探针 | 整个文件 |
| 声明 / 绑定 / 成员 / include / 缓存键 | 5 个文件 | ~20 处 |

**合计约 430 行移除。**

## 3. 延后删除的原因（M5-8 已记录）

准备删时发现测试里 3 类断言测的是**真实语义**（ADD vs MULTIPLY、「-8% 变 +8%」）。
但派生层只暴露计数，那些断言无处可迁 → 先加 `get_effective_stat_value` 桥（M5-8），
再补内核断言（本轮 `test_negative_delta_folds_additively`，93 checks），最后才删。

**顺序是对的：可观测性 → 覆盖迁移 → 删除。**

## 4. 一个必须记录的陷阱：GDScript 测试会静默降级

删完桥但**还没删测试函数**时，跑测试得到：

```
ideology effect metric publish: 289 checks, 0 failures     ← 看起来全绿
SCRIPT ERROR: Invalid call. Nonexistent function 'get_ideology_cell_program_summary'
SCRIPT ERROR: Invalid call. Nonexistent function 'set_ideology_cell_program_entry_for_test'
```

**函数抛出后被中止，check 计数器只是停止递增，测试仍然报 0 failures。**

- 删除前：289 checks
- 留着报错：289 checks / 0 failures（**平面断言早已不执行**）
- 真正删除后：**268 checks / 0 failures，无 SCRIPT ERROR**

**如果我只跑回归看「289/0 通过」就收工，会以为覆盖还在。**

## 5. 覆盖去哪了

| 原断言 | 现在的位置 |
|---|---|
| ADD vs MULTIPLY 折叠 | 内核 `A` 组（`derived_layer_rebuild_test.cpp`）|
| 负幅度按加法折叠（「-8% 变 +8%」）| 内核 **`N` 组**（本轮新增，含 base=2 的区分性用例：1.875 vs 1.75）|
| 平面 entry 的 coefficient 列 | 随平面删除；等价问题「贡献是否到达逐格值」由 B7 的 `get_effective_stat_value` 断言 |
| 「卡覆盖整国」| B7 `front cells=3200` |

## 6. 验证

| 项 | 结果 |
|---|---|
| 构建 | **exit 0** |
| B7 / B8 / B10 | 20/0、18/0、16/0 |
| x1b / tag_snapshot_stress | 142/0、38/0 |
| effect_metric_publish | **268/0，无 SCRIPT ERROR** |
| content / target_selector / effect_instance / tag_source_selector / progression | 67/2/51/106/21 全 0 |
| runtime | 82/0 |
| **mechanism_matrix** | **1129/3 —— 与基线完全一致** |
| 内核 | **93 / 0** |

## 7. §15.7 进度

| 任务 | 状态 |
|---|---|
| A–F 全部 ON | ✅ 265/265 |
| **删除旧 v1 平面** | ✅ **本轮完成** |
| 删除迁移开关 | ✅ M5-2 |
| 32 常量改 legacy 名 | ✅ |
| B1–B12 / save-load / 权威翻转 / UI | ⬜ 仅 B7/B8/B10 |
| 文档与 skill 同步 | ⬜ |

## 8. 局限

- 仍残留少量只被平面写过的计数器（`_cell_plane_builds` 等）永不递增；无害但可再清一轮。
- `ideology_cell_program.h` 仍存在但已无包含者，未删除。
- B1–B6/B9/B11/B12、save/load、权威翻转、UI 未测。
- 未在真实生成世界、release DLL 验证。
