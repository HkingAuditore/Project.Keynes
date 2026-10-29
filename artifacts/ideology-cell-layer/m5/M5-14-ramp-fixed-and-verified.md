# M5-14 修复 ramp 数值错误：派生路径现在执行卡片的指令流

| 项目 | 内容 |
|---|---|
| 里程碑 | [§13.1 第 2 层](22-cell-program-cap-removal-plan-v3.md) / §18.2 第 1 项 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **oracle 12/0，逐点 `delta = 0.00000000`**；全回归 **22 / 22** |
| 影响 | 24 个 kind-12 ramp 卡的数值从「错误」变为「与解释器逐点相等」|

## 1. 修了什么

**修复前**：派生路径对 ramp 项只做 `metric * ramp_scale`，其中 `ramp_scale = term.value * stacks / Q16`。
注释声称「authored MIN/MAX 已界定采样」——但派生路径**不执行指令流**，所以采样的是原始 metric。

实测 `salt_monopoly_l1`（`CONST 655 → READ_METRIC → CONST 983040 → MIN → MUL → EMIT`）：

| 侧 | metric = 40 | metric = 120 |
|---|---:|---:|
| 解释器 | 9825 | 9825（被 MIN 钳到 15）|
| 派生（修复前）| **40.0** | **120.0** |

派生值远超 stat 的 `clamp_max = 16.0`，于是**一律拉满**。卡片设计是 +15%。

## 2. 修法：用已有的栈机器，不重算算术

`EffectRuntime::evaluate_program_magnitude_for_metrics()` 早就存在（M3-2 实现，且不改运行时状态，
可用于 worker 路径）。四处接线：

| # | 改动 |
|---|---|
| 1 | `DerivedProgramContribution::Term` 增加 `std::string program_key` |
| 2 | 收集器的 ramp 分支填 `row.program_key = program`，并删掉那句错误注释、换成实测数据 |
| 3 | `DerivedMaterializeOptions` 增加 `DerivedProgramMagnitudeSampler`（按 (program, cell) 返回幅度比值）|
| 4 | `ideology_runtime` 建 `_derived_program_sampler`：每格采样全部 metric → 调 VM → 返回 `magnitude / Q16` |

物化器的 ramp 分支**优先**用它；没有 sampler 时才回退到 `metric * ramp_scale`（并保留原注释说明
该回退只在「指令流恰为 `EMIT metric` 且系数为 1」时正确）。

**为什么不在派生侧重新实现指令流**：24 张卡各有各的形状，重实现就是这次漂移的成因。

## 3. 验证：逐点精确相等

```
[oracle] metric=5.000    derived=0.04997253  interp/Q16=0.04997253  delta=0.00000000
[oracle] metric=10.000   derived=0.09994507  interp/Q16=0.09994507  delta=0.00000000
[oracle] metric=120.000  derived=0.14991760  interp/Q16=0.14991760  delta=0.00000000
[oracle] clamp: high=0.14991760 huge=0.14991760
[oracle] program_evaluations=4400 failures=0
=== oracle cross-check: 12 checks, 0 failures ===
```

| 断言 | 意义 |
|---|---|
| 三个点 `derived == interp/Q16` | **绝对值相等，不是比值相近** —— 尺度错或函数错都会失败 |
| `5 → 10` 时值翻倍（0.050 → 0.100）| ramp 是活的，未饱和 |
| `120` 与 `500` 相等（0.14992）| **MIN 钳位被复现** |
| 饱和值 = `15 × 655 / Q16` | 等于程序自己的常量 |
| `program_evaluations = 4400`、`failures = 0` | **VM 真的跑了**，不是回退路径 |

取三个点而不是两个，是因为两个**都超上限**的值会平凡相等；必须有一个点在上限之下才有区分度。

## 4. 一处我自己的错误断言

第一版写「above the clamp the contribution saturates (high == mid)」，用 `mid`（metric=10，**未饱和**）
去比 `high`，必然失败。**代码是对的，断言是错的。** 改为 `high` 比 `huge`（都超上限）。

## 5. 回归

**22 / 22 全绿**，含：

| fixture | 结果 |
|---|---|
| **oracle_cross_check** | **12 / 0** |
| B7 / B8 / B10 | 20/0、18/0、16/0 |
| x1b / tag_snapshot_stress | 142/0、38/0 |
| ramp / ramp_materialize | 13/0、12/0 |
| effect_metric_publish / content / runtime / progression | 268/0、67/0、82/0、21/0 |
| 其余 | 全 0 |

## 6. 对 §18 的影响

| 项 | 修复前 | 现在 |
|---|---|---|
| §18.2 第 1 项「同输入 VM／adapter／term 对照」| 无证据 | **有证据**（12 检查，绝对值相等）|
| §18.1 「派生 program 数值正确」| 未达成 | **24 个 ramp 卡已交叉验证**；常数卡由内核 A/N 组覆盖 |
| 「265/265 全派生」的含义 | 只说明判定成立 | 现在 ramp 类的**数值**也有对照 |

**但仍不等于 §18 全部完成**：常数卡与解释器的逐格对照尚未做，权威组合／save-load／B1–B6 等 17 项仍无证据。

## 7. 未验证的性能影响

每格每 ramp 项现在多一次「全 metric 采样 + VM 求值」。B7 实测 `program_evaluations=4400`。
**性能未重测**（M4-24 的 1 ms slice 门槛需要重新核对）——这是本次修复的主要未验证代价。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `derived_cell_materializer.h` | `Term::program_key`、`DerivedProgramMagnitudeSampler`、options 字段 |
| `derived_cell_materializer.cpp` | ramp 分支优先走 program sampler |
| `ideology_runtime.h/.cpp` | `ensure_derived_program_sampler()`、`derived_program_evaluations`/`_failures` 导出、收集器填 `program_key` |
| `tests/ideology/ideology_oracle_cross_check_test.gd` | 12 检查，绝对值对照 |
