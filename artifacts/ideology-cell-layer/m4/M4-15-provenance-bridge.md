# M4-15 来源国溯源桥接通：B10 16/0，全回归 18/18

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.2 B10 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`get_derived_multi_country_report` 接通**；B10 **16 / 0**；全回归 **18 / 18** |
| 结论 | 溯源可查询；但「两国影响同一格」在不相交领土下不存在，需 kind 14/16 |

## 1. 新增的溯源桥

```
[B10] multi-country = { "ok": true, "rows": 2, "cells": 6400,
                        "multi_country_cells": 0, "max_contributors": 1,
                        "countries": [4294967296, 4294967297], "generation": 2 }
```

**`countries` 有两个句柄 —— 两国都真实到达了派生层。** 这是「多国合并为单一 front」的直接证据。

## 2. 为此修复的三处真实缺陷

### 2.1 `builder.add` 无法承载 `contributor_count`

```cpp
// 修复前：只有 5 个参数，计数永远为 0
bool add(int32_t stat_id, int32_t cell, uint64_t source_country,
         double add, double factor)
```

实测 `max_contributors = 0`，即使每格至少有 1 个国家。

### 2.2 `builder.add` 无条件覆盖来源国

```cpp
// 修复前
slot.source_country = source_country;   // 后写者赢
// 修复后
if (slot.source_country == 0) slot.source_country = source_country;
else if (source_country != 0 && slot.source_country != source_country)
    ++slot.contributor_count;
```

后写者赢意味着边境格报的是**最后折叠的那个国家**，而不是「两国共有」。

### 2.3 materializer 没有把计数传下去

`builder.add(..., slot.contributor_count)` 缺失。

## 3. 一个必须说清的测量结果

**`max_contributors = 1`，这是正确的。**

两国各拥有**不相交**的一半领土：

- A 拥有 `x < 40`
- B 拥有 `x >= 40`

`SELECTOR_OWN_TERRITORY` 从 A 的 anchor 出发只会到达 A 的格，B 同理。**没有任何 `(stat, cell)` 能有两个拥有者。**

我原来的断言写的是 `>= 2`，那是我对场景的误解，不是产品缺陷。已改为断言**恰好 1**：

- 等于 0 → 溯源没接通（真缺陷）
- 等于 1 → 正确（领土不相交）
- 等于 2 → 说明我构造的两半其实不不相交

**「多国影响同一目标」需要 kind 14/16 的来源展开跨过边境**，`OWN_TERRITORY` 在不相交领土下不可能做到。这一项记为开放。

## 4. 全回归 18 / 18

| fixture | 结果 |
|---|---|
| **B10 multi-country** | **16 / 0** |
| **B7 wide territory** | **14 / 0** |
| **B8 source overlap** | **18 / 0** |
| tag_snapshot_stress | 38 / 0 |
| x1b source count | 142 / 0 |
| tag_source_selector | exit 0 |
| cell_layer_catalog | 9 / 0 |
| cell_layer_unbounded | 1 / 0 |
| cell_layer_numeric | 7 / 0 |
| cell_layer_ramp | 13 / 0 |
| cell_layer_ramp_materialize | 12 / 0 |
| cell_layer_adr02 | 19 / 0 |
| cell_layer_merge | 20 / 0 |
| cell_layer_scope_union | 20 / 0 |
| cell_layer_slice_budget | 2 / 0 |
| target_selector | exit 0 |
| effect_instance | exit 0 |
| content | exit 0 |

**PASS = 18，FAIL = 0。**

## 5. 局限

- **「两国影响同一格」未验证**：需要 kind 14/16 的跨境外溢，`OWN_TERRITORY` 做不到。
- **来源撤销仍阻塞**：`run_effect_daily` 在无头环境静默等待（M4-14 记录）。
- 溯源只统计 `contributor_count`，未暴露「哪两个国家、各贡献多少」。

## 6. 验证

| 项 | 值 |
|---|---|
| 构建 | exit 0 |
| B10 | **16 / 0** |
| 全回归 | **18 / 18** |
| `derived_layer_rebuild_test` | 49 / 0 |
| 覆盖率门禁 | 6 / 6 |
