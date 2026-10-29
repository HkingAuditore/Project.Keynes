# M4-6 必须如实报告：此前多轮「零回归」建立在一个 bug 之上

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结论 | **M2/M3 反复报告的「回归零判定变化」并不完全成立** |

## 1. 事实

| 回归轮次 | `ideology_tag_snapshot_stress_test` |
|---|---|
| M2 final2 | **pass 37/0** |
| M3 ramp-mat | **pass 37/0** |
| M3 admit | **pass 37/0** |
| M3 rollout-on | **pass 37/0** |
| M4（I01 修复后）| **failures 37/2** |

我在 M2-、M3- 的报告里多次写下「回归零判定变化（15 fixture）」，把这一项当作证据。

**但那个全绿的前提是 I01 有 bug。**

## 2. 机制

`ideology_tag_snapshot_stress_test` 用 `SEL_OWN_TERRITORY`（kind 12），在 `Continuous` 下
**已经走派生路径**（M3-12 打开的）。它断言：

```gdscript
_expect("tag flip creates one instance per tagged cell ...",
    instances_after_flip == COUNTRY_COUNT * per_country_cap)   // 192
```

**I01 有 bug 时**：派生分支产生 rows，实例路径也创建实例 → `after_flip == 192` → 断言通过。
**I01 修好后**：派生 program 不创建实例 → `after_flip == 0` → 断言失败。

**这个断言一直在验证 bug 的副产品，而不是一个正确行为。**

## 3. 这改变了什么

### 3.1 我之前报告的「零回归」需要重新表述

正确的说法应该是：

> 在 I01 缺陷存在的前提下，15 个 fixture 的判定与 M0 基线一致。

而不是：

> 改动没有破坏任何既有断言。

两者差别很大：前者说明测试与实现共享同一个错误假设。

### 3.2 这也解释了 M3-12 的一个矛盾

M3-12 我打开 rollout 后报告「回归零判定变化」，同时观察到「265 个 program 具备派生能力但生产仍走实例路径」。
**当时我以为那是 rollout 还没生效**，实际是 I01 让两条路径同时运行。

### 3.3 §13.1 第 2 层（同输入对照）再次被证明是必要的

如果 M2 阶段就做了「派生 vs 实例逐格对照」，I01 的双重应用会在当时暴露，
而不是拖到 M4 才由一次失败的修复尝试间接发现。

## 4. 当前仓库状态（必须明示）

| 项 | 状态 |
|---|---|
| I01 修复 | **已实现，代码正确**（12 个数值分歧消失可证）|
| `Continuous` rollout | 开启 |
| `ideology_tag_snapshot_stress_test` | **37/2（失败）** |
| `ideology_x1b_source_count_test` | 142/0（`Continuous` 下 kind 16 未启用）|
| 其余 13 个 fixture | 与 M0 一致 |

**仓库现在不是全绿。** 这是 I01 修复的直接后果，不是意外。

## 5. 两个选项及其代价

### 选项 A：保留 I01 修复，迁移 6 个断言（正确但未完成）

需要：
1. 加桥暴露派生 front 的逐格值（现在的 `get_derived_materialize_report` 只有汇总）。
2. 6 个断言改成读 front。
3. `tag_snapshot_stress` 的 tag filter 语义要用 front 重新验证（它测的 `after==192` 应改为
   「front 里该 stat 有 192 个 cell」或按派生语义重写）。

**代价**：一个桥 + 6 处断言 + 一个 fixture 的语义重写。

### 选项 B：回退 I01 修复（回到全绿，但保留缺陷）

**代价**：I01 缺陷继续存在；M4 无法推进；12 个数值分歧继续潜伏。

## 6. 我的建议

**保留 I01 修复**，因为：
- 它是方案 §4.5 的硬不变量，缺陷本身比 2 个红色 fixture 严重；
- 12 个数值分歧的消失是**派生路径真正生效**的第一个证据；
- 回退等于把一个已知的正确性缺陷留在代码里。

**但不应该把当前状态报成"完成"。** M4 需要：
1. 派生 front 的逐格值桥；
2. 6 个断言迁移；
3. 然后才是 `Sources` 的 rollout 与 M5。

## 7. 本次会话的最终边界

| 里程碑 | 状态 |
|---|---|
| M0 | ✅ |
| M1 | ✅ |
| M2 | 32 上限三处移除、性能实测、rollout 打开（但「零回归」有前提）|
| M3 | 265/265、ramp 求值器、物化器、理念激活 |
| **M4** | **I01 真实违例已修复**；6 个断言待迁移；`Sources` 未启用 |
| M5 | ❌ 未开始 |

**目标要求做到 M5。实际到 M3 完整 + M4 的核心缺陷已修。这个差距是真实的，不用「会话结束」去掩盖。**
