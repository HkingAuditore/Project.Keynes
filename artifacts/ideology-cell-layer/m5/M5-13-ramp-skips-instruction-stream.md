# M5-13 严重缺陷确认：派生 ramp 路径跳过卡片的指令流

| 项目 | 内容 |
|---|---|
| 里程碑 | [§13.1 第 2 层](22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 严重性 | **严重** —— 24 个 ramp 卡在派生路径上给出与卡片设计无关的值 |
| 状态 | 已确认，**未修复** |

## 1. A 被排除

`metric_keys[57] = "country.extractive_cell_count"`，且 **dense index 与 `FamilyEffectMetricId` 是恒等映射**
（`metric_keys[0] = "family.magnitude_q16"`，即 Family id 0）。

所以解释器的 `READ_METRIC 57` 与 `set_effect_metric_override_for_test(57, …)` **是同一个 metric**。
两侧输入一致，比较有效。

## 2. B 成立：两侧算的不是同一个东西

卡片 `salt_monopoly_l1` 的指令流：

```
CONST 655  →  READ_METRIC 57  →  CONST 983040  →  op=8 (MIN)  →  op=6 (MUL)  →  EMIT
```

解释器逐格结果 = `min(metric, 983040) * 655 / 65536`：

| metric | min(...) | 解释器结果 |
|---:|---:|---:|
| 2621440（40.0）| 983040 | **9825.0** |
| 7864320（120.0）| 983040 | **9825.0** |

两次都被 MIN 钳到 15.0，所以恒定。

派生侧实测 `derived_add`：

| metric | `derived_add` | 反推公式 |
|---:|---:|---|
| 2621440 | **40.0** | `metric / 65536` |
| 7864320 | **120.0** | `metric / 65536` |

**派生侧等于 `metric * term.value / Q16`（`term.value = 1`），既没有 MIN，也没有那个 655。**

## 3. 根因

`collect_effect_activations` 对 ramp 项：

```cpp
if (ramp && ramp_metric_id >= 0) {
    row.magnitude_source = RampMetric;
    row.metric_id = ramp_metric_id;
    row.ramp_scale = term.value * stacks / Q16;   // ← 只有 modifier 定义的系数
    row.ramp_has_ceil = false;
    // 注释声称：「The authored MIN/MAX inside the instruction stream already
    // bound the sample」
}
```

**那句注释是错的。** 派生路径**不执行指令流**——它只采样原始 metric，再乘 `ramp_scale`。
指令流里的 `MIN`、`CONST 655` 全部被跳过。

只有「指令流恰好是 `EMIT metric`、系数为 1」时这个等价才成立。实际 24 个 ramp 卡都不是。

## 4. 可观测后果：数值被打到上限

现场探针（`economy.city.building.extractive_output_factor`，`clamp_max = 16.0`）：

```
{ "value": 16.0, "derived_add": 400.0, "derived_factor": 1.0, ... }
```

**`derived_add` 是 400，stat 的上限 16，所以值直接饱和到 16.0。**

卡片设计的意图是 `min(count,15) * 655 / Q16 ≈ 0.15`（+15%），派生路径给的是「拉满」。
**这不是精度偏差，是量级错误。**

## 5. 影响面

| 范围 | 说明 |
|---|---|
| 24 个 kind-12 ramp 卡 | 全部走这条路径（覆盖率门禁：`ramp deferred = 0`，即全部被判为可派生）|
| 表现 | 贡献幅度与卡片指令流无关；多数会被 stat 的 `clamp_max` 吃掉，等于「一律拉满」 |
| 未受影响 | 常数卡（kind 12/14/16 中的非 ramp 项）走 `add`/`factor`，正确 |

## 6. 为什么之前的测试没抓到

| 已有测试 | 为什么没抓到 |
|---|---|
| `ideology_cell_layer_ramp_materialize_test`（12 检查）| 纯核：手搓 Term，断言 `metric * ramp_scale` 的算术一致 —— **它验证的正是这个错误假设** |
| `derived_layer_rebuild_test` L 组 | 同上，手搓 Term |
| B7 的 `_verify_ramp_card` | 只断言 `evaluated > 0`，**从不与解释器比对数值** |
| 覆盖率门禁 | 只数「是否被判为 DerivedCell」，不看数值 |

**四个测试都在验证同一套假设，没有任何一个把派生结果与解释器对照。**
这正是丢失的 735 检查 oracle 的价值。

## 7. 修复方向（未实施）

不要在派生路径重新实现指令流。**用已有的 VM**：

`EffectRuntime::evaluate_program_magnitude_for_metrics(program_key, metric_values, …)`
（M3-2 已实现，且注释说明它不改运行时状态，可用于 worker 路径）。

需要改的接线：

1. `DerivedProgramContribution::Term` 增加 `program_key`；
2. `collect_effect_activations` 对 ramp 项填入该 key，并**不再**用 `term.value` 当尺度；
3. 物化器的 ramp 分支改为「取该格的 metric 数组 → 调 VM → 得到 magnitude」，
   而不是 `metric * ramp_scale`；
4. `ideology_runtime` 的采样器改为按 (program, cell) 调 VM（country-scope metric 仍可 memo）。

代价：每格每 ramp 项一次 VM 求值。B7 实测 1600 格 × 1 项，需要重新测性能。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_oracle_cross_check_test.gd` | 对照夹具，**当前 6 checks / 1 失败**（它抓到了这个缺陷）|
| 本报告 | 算术证明与影响面 |

## 9. 诚实的结论

**这个缺陷意味着：ramp 卡在派生路径上的数值是错的。**

在此修复之前，覆盖率的「265/265 全派生」只说明**判定**成立，不说明**数值**正确。
`§18.2 第 1 项` 必须保持「无证据」，而 `§18.1` 关于数值正确性的条目也应视为未达成。
