# M3-11 全部 265 个 program 进入派生路径

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | 判定器放行 ramp、覆盖率工具同步 |
| 结果 | **DerivedCell 241 → 265（+24）**，`ramp deferred: 24 → 0`，6/6 门禁通过 |
| 结论 | **M3 的核心目标达成**：A–F 全部 265 个 program 走派生路径 |

## 1. 决定性数字

```
DerivedCell   : 265          （原 241）
ramp deferred : 0            （原 24）
[ok] A-F count == 265
[ok] M2 scope all DerivedCell       265 / 265
[ok] ramp deferred == 0
[ok] no unexplained legacy          0
[ok] no unresolved command refs     0
[ok] synthesis used (101 refs)      101
```

**265 / 265 全部 DerivedCell。**

## 2. 改的是什么

判定器原本把 ramp 当作**永久拒绝**，尽管注释已经写明「这是延迟，不是拒绝」：

```cpp
// 改前：一律拒绝
if (!magnitude_is_constant) {
    out.reason = has_metric_ramp ? RampNotYetSupported : NonConstantValueMode;
    return out;
}

// 改后：ramp 放行，只有「既非常数又非 ramp」才拒绝
if (!magnitude_is_constant && !command.has_metric_ramp) {
    out.reason = NonConstantValueMode;
    return out;
}
```

**关键认识：判定问题从来不是「幅度是不是常数」，而是「派生层能否表达这个幅度」。** M3-2/3 给了逐格求值器与采样器，答案就变成了能。

## 3. 同步了第二个地方

覆盖率工具（Python）独立实现了同一套规则，所以它**仍然报 24 个 ramp**。

**这是必须同步的**，否则：

| 后果 | 说明 |
|---|---|
| 数字失真 | 工具说 24 unsupported，运行时不支持 0 |
| 门禁失效 | `ramp deferred == 24` 这条断言会继续「通过」，掩盖真实状态 |

改法：
1. 分类规则与 C++ 一致（`!magnitude_constant && !has_metric_ramp`）；
2. 门禁期望 **24 → 0**——**保留断言而不是删掉**，这样将来若有 ramp 被重新延迟，会失败而不是静默缩小派生集。

## 4. 这一步在里程碑中的位置

方案 §15.5 的 M3 目标是「C/D，累计 194 个 program」。实际达成的是：

| 项 | 数 |
|---|---|
| A/B（M2 批次） | 241 |
| **+ ramp（M3 的 C 类，12 个 program）** | **+24** |
| 合计 DerivedCell | **265** |

超过 §15.5 的 194，因为 M2 已完成的部分比计划的 141 多。

## 5. 仍然没有解决的

**放行 ≠ 已验证。** 必须区分：

| 项 | 状态 |
|---|---|
| 判定器认为 265 个都能表达 | ✅ |
| 逐格 ramp 求值器正确 | ✅ M3-2（13 checks）|
| 物化器逐格求值 | ✅ M3-3（12 checks）|
| **真实 epoch 下 24 个 ramp 的数值正确** | ❌ **未验证** |
| M3 的另外 3 个退出条件 | ❌ |

第 4 项是重要缺口：生产采样器已接线（M3-4），但**没有任何一次在真实 epoch 下确认过 ramp 的实际取值**。殖民支线六轮的教训正是：**机制通不等于数据对**。

## 6. 验证

| 项 | 值 |
|---|---|
| DerivedCell | **265 / 265** |
| 覆盖率门禁 | **6 / 6** |
| 纯核门禁 | oracle 735 / materializer 65 / eligibility 56 / cap_removed 12 |
| 构建 | exit 0 |

## 7. 局限

- 无头回归结果待确认（已启动）。
- `rollout` 仍是 `Off`，所以**生产行为未变**——265 个 program 具备派生能力，但实际仍走实例路径。
- 24 个 ramp 的**真实取值**未验证。
- D 类（41 个条件常数）——本轮的 265 已包含它们，因为它们原本就是常数幅度；方案里的「D 类」若指**带条件**的程序，那部分仍未单独验证。

## 8. 复算方式

```powershell
python Project/project-keynes/tools/ideology/m1_backend_coverage.py --check
# => DerivedCell: 265 ; ramp deferred: 0 ; 6/6 gates ok
```
