# M4-5 I01 修复的完整影响与最终状态

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | I01 修复正确；**2 个 fixture 的 6 个断言因此失效**，需要迁移 |
| 决定 | 回退 `Continuous`，把 I01 修复**连同其依赖的断言迁移**一起作为 M4 的完整单元 |

## 1. I01 修复是对的，但它暴露了测试的假设

### 1.1 修复内容

```cpp
// 改前：实例路径（out_derived == nullptr）永远创建实例
if (out_derived != nullptr && rollout_enabled(kind) && backend == DerivedCell) { ... }

// 改后：判定只看「这个 program 是否应该是派生」
const bool derive_this_program = rollout_enabled(kind) && backend == DerivedCell;
if (derive_this_program && out_derived == nullptr) continue;  // 不发实例
if (derive_this_program) { ...派生 rows...; continue; }
```

**这是 I01「one program, one backend」的正确实现。**

### 1.2 效果（`Sources` 下）

| 项 | 修复前 | 修复后 |
|---|---:|---:|
| `ideology_x1b_source_count_test` 失败 | 13 | **4** |
| 12 个数值分歧（1.23999 vs 1.12）| 12 | **0** |
| 剩余失败类型 | 数值 + 实例句柄 | **全部是实例句柄** |

**数值分歧全部消失。** 这证明 M4-2/M4-3 追的 per-source scale 问题，本质是 I01 的双重应用。

### 1.3 但它打破了 2 个 fixture 的 6 个断言

完整 15-fixture 回归（`Continuous` + I01 修复）：

```
CHANGED: ideology_x1b_source_count_test     M0=pass/142/0  NOW=142/4
CHANGED: ideology_tag_snapshot_stress_test  M0=pass/37/0   NOW=37/2
```

**M3 回归时这个 fixture 是 37/0**（rollout `Continuous`、无 I01 修复），所以是修复本身打破的。

失败内容：

```
[FAIL] tag flip creates one instance per tagged cell up to the selector cap
       (after=0, expected 192)
[FAIL] cell instance count tracked the tag change (tag_changes=0)
```

`after=0` —— **实例数为 0，因为该 program 现在走派生路径**。

## 2. 为什么这些断言以前能过

`ideology_tag_snapshot_stress_test` 用 `SEL_OWN_TERRITORY`（kind 12），在 `Continuous` 下**已经走派生路径**。
但因为 I01 有 bug，实例**同时**被创建，所以「tag flip 后 192 个实例」的断言恰好能过。

**那个断言一直在验证一个 bug 的副产品。** I01 修复后它必然失败。

## 3. 因此这些不是"回归"，而是"断言过时"

| 断言 | 旧假设 | 新事实 |
|---|---|---|
| `tag flip creates one instance per tagged cell` | 派生 program 也建实例 | 派生 program 不建实例 |
| `cell instance count tracked the tag change` | 同上 | 同上 |
| `T1 target handles stay distinct` | 同上 | 同上 |
| `T2 the centre target remains held` | 同上 | 同上 |
| `T3 radius 3 returns 1..3` | 同上 | 同上 |
| `T8 truncation keeps the 32-cell ceiling` | 同上 | 同上 |

**6 个断言，全部需要改成读派生 front 而不是实例列表。**

## 4. 最终状态（安全）

| 项 | 值 |
|---|---|
| rollout | **`Continuous`** |
| I01 修复 | **已实现并保留**（代码正确） |
| 15-fixture 回归 | 7 个 NON-PASS（5 个为 M0 既有 + **2 个由 I01 修复暴露**）|
| `ideology_x1b_source_count_test` | 142/0（`Continuous` 下 kind 16 未启用，不受影响）|
| `ideology_tag_snapshot_stress_test` | **37/2**（kind 12 已派生，断言过时）|

**注意：`tag_snapshot_stress` 现在在 `Continuous` 下也失败**，因为 I01 修复对 kind 12 生效了。
这意味着**当前仓库状态不是全绿**。

## 5. 这是必须如实报告的状态

| 项 | 状态 |
|---|---|
| I01 修复 | ✅ 正确，且有数值证据（12 个分歧消失）|
| 回归基线 | ❌ **2 个 fixture 从 pass 变 failures** |
| 原因 | 6 个断言假设「派生 program 也建实例」，与 I01 冲突 |

**我没有把状态掩盖成全绿。** 正确的处置是：迁移那 6 个断言，需要先加一个暴露派生 front 逐格值的桥
（`get_derived_materialize_report` 只有汇总数，没有逐格值）。

## 6. M4 的完整剩余清单

1. 加桥 `get_derived_cell_front_values()` 暴露 front 的 (stat, cell, add, factor)。
2. 迁移 6 个断言读该桥。
3. 重跑 `Sources`，目标是 142/0 + 37/0。
4. 再做 M4 的其余任务（stamp/scratch、边境外溢、per-tag changed words）。
5. 最后 M5。

## 7. 本次会话的净成果

| 里程碑 | 状态 |
|---|---|
| M0 / M1 | ✅ 完成 |
| M2 | 32 上限三处移除、性能实测、rollout 打开 |
| M3 | 265/265 DerivedCell、ramp 求值器、物化器、理念激活 |
| **M4** | **I01 真实违例已找到并修复**（12 个数值分歧消失），6 个断言待迁移 |
| M5 | ❌ 未开始 |

**目标要求做到 M5，实际到 M3 完整 + M4 的核心缺陷已修但断言未迁移。**
