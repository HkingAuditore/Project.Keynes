# M2-17 rollout ON blast-radius experiment — a negative result worth recording

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §15.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 实验 | 临时把 `kCellProgramRollout` 设为 `Constants`，跑完整回归 + e2e |
| 结果 | 回归零变化，**但零变化不能证明安全** —— 派生分支根本没被执行 |
| 结论 | **ON 无法在现有夹具中验证**；已回滚到 `Off` |

## 1. 实验设计

想回答一个此前只能猜的问题：**把 rollout 打开会破坏多少既有行为？**

做法：`kCellProgramRollout = Constants`（启用 A/B 批次，kind 12）→ 重建 → 跑 15 fixture 回归 + e2e。

## 2. 结果一：回归零变化

```
changed verdicts with rollout ON: 0
```

15 个 fixture 逐项与 M0 基线**完全一致**，包括 6 项失败的数量与检查数。

第一眼这是好消息。

## 3. 结果二：但它什么都没证明

e2e 夹具显示：

```
[e2e] materialize={ "programs_seen": 0, "programs_derived": 0, ... }
[e2e] cell_layer_rebuild_visits=4
```

**物化器运行了 4 次，但一次都没看到程序。** 而 rollout 已经打开、判定器也会判成 DerivedCell（覆盖率工具报告 241 个）。

原因在派生分支的位置：

```cpp
// ideology_runtime.cpp:2180-2206
std::vector<EffectTarget> targets;
if (!resolve_effect_targets(country, state, program, metadata,
        effect_program_hash(program), targets))
    continue;                                    // ← 这里就退出了
...
if (out_derived != nullptr &&
    cell_program_rollout_enabled(metadata.target_selector_kind) &&
    backend.backend == CellProgramBackend::DerivedCell) {
```

**`resolve_effect_targets` 先返回 false，整个派生分支不可达。** 而它失败的原因是 M1-13 已经定案的那条：`_epoch_cell_country` 只在真实 epoch 内填充。

## 4. 所以这个实验的结论是

> **rollout ON 会破坏什么，目前无法回答。**

零回归不是「ON 是安全的」，而是「ON 没被走到」。把这个结果当成安全性证据，会是本轮最严重的错误——而它恰恰是最容易被误读的那种结果。

## 5. 已回滚

`kCellProgramRollout` 恢复为 `Off`，重新构建通过。DLL 回到 `Off` 状态。

## 6. 这给 M2 的边界画得更清楚了

| 问题 | 答案 |
|---|---|
| 32 上限在目标解析层是否消失 | ✅ 是（12 条断言） |
| 内容是否不再写 32 | ✅ 是（194/194 为 `(0,0)`） |
| 校验是否放宽 | ✅ 是（两层） |
| 性能是否可接受 | ✅ p50 5.99 us/格，§14.3 余量 15.9% |
| **rollout ON 是否安全** | ❓ **无法测**（派生分支不可达） |
| 派生层端到端是否产生行 | ❓ **无法测**（同一原因） |

后两行是同一个缺口，而它需要**真实 epoch**——M1-8/M1-13/M2-9/M2-14 反复确认的那件事。

## 7. 局限

- 本轮只试了 `Constants` 档，未试 `Continuous` / `Sources`。
- 「零变化」的判定基于 fixture 的 checks/failures 数字，未逐条比对日志内容——若某 fixture 内部数值变了但断言数不变，不会被发现。这是既有回归工具的固有局限。
- 未验证 `resolve_effect_targets` 在 ON 状态下是否真的一次都没成功；「不可达」是从 `programs_seen=0` 反推的。

## 8. 复算方式

```powershell
# 1. 临时改 gdext/src/cell_program_eligibility.h:
#    kCellProgramRollout = CellProgramRollout::Constants
# 2. 重建，然后：
powershell -NoProfile -ExecutionPolicy Bypass -File `
  Project/project-keynes/tools/ideology/run_m0_baseline_tests.ps1 `
  -OutDir artifacts/ideology-cell-layer/m2/regression-rollout-on
# => 零变化
# 3. e2e:
# => programs_seen=0，证明派生分支未执行
```
