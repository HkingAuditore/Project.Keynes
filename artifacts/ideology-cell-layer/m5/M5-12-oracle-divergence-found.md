# M5-12 重建 oracle：基础设施就位，发现一处待查分歧

| 项目 | 内容 |
|---|---|
| 里程碑 | [§13.1 第 2 层](22-cell-program-cap-removal-plan-v3.md) 同输入逐格对照 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | 对照测试建好并两侧都能测量；**发现派生层与栈机器的结果不一致** |
| 状态 | **开放** —— 未通过，未掩盖 |

## 1. 为什么重建

`derived_layer_oracle_test`（735 检查）的源码在一次 `git pull` 中随未跟踪文件丢失。
没有它，§18.2 第 1 项「同输入 VM／adapter／term 对照」从「通过」退回「无证据」。

## 2. 建的是什么

`tests/ideology/ideology_oracle_cross_check_test.gd`：

- 用真实卡片 `salt_monopoly_l1`（24 个 kind-12 metric-ramp 卡之一，指令流 `READ_METRIC 57`）
- `set_effect_metric_override_for_test` 冻结 metric 为两个不同的值，各跑一次重建
- **派生侧**：`get_effective_stat_value().derived_add`
- **解释器侧**：`evaluate_effect_program_magnitude()`（→ `run_program_machine`）
- **比较比值** `derived(M1)/derived(M2)` vs `interp(M1)/interp(M2)`

比值是刻意的：派生贡献带一个 fold 侧尺度（`ramp_scale = term.value * stacks / Q16`），
解释器不给。重建那个尺度等于重算被测代码；比值把它约掉，且**不会因尺度 bug 而误通过**。

## 3. 实测结果：不一致

```
[oracle] stat economy.city.building.extractive_output_factor -> stat_id 6
[oracle] front cells=400 stat_count=1 | mat seen=400 derived=400 rows=400
[oracle] derived_add: M1(2621440)=40.00000000  M2(7864320)=120.00000000  ratio=0.33333
[oracle] interp magnitude: M1=9825  M2=9825  ratio=1.00000
[oracle] derived=0.333333 vs interpreter=1.000000  (delta=0.666667)
```

| 侧 | M1（metric = 40.0）| M2（metric = 120.0）| 行为 |
|---|---:|---:|---|
| 派生 | **40.0** | **120.0** | 线性跟随 metric，**未饱和** |
| 解释器 | 9825 | 9825 | **恒定，已饱和** |

这条卡的指令流是：`CONST 655` → `READ_METRIC 57` → `CONST 983040` → `op=8` → `op=6` → `EMIT`。
`983040/Q16 = 15.0`，`op=8` 是 MIN。所以**解释器在两种输入下都被 MIN 钳到 15**，
而**派生层没有钳**。

## 4. 两种可能（我还没区分开）

### 可能 A：我的 metric 槽位映射错了

`READ_METRIC` 的 `arg0` 是 **`metric_keys` 的稠密索引**，不是全局 `FamilyEffectMetricId`
（这一条在本仓库里已被记录过两次）。而我：

- 对解释器直接传一个 `metrics[57] = value` 的数组（按稠密索引解释）
- 对派生侧用 `set_effect_metric_override_for_test(57, ...)`（按 FamilyEffectMetricId 解释）

**两侧可能根本不是同一个 metric**，那样这个比较毫无意义。

### 可能 B：真实分歧

若槽位映射是对的，则派生层**没有应用指令流里的 MIN/MAX**。收集器把
`ramp_has_ceil = false`、`ramp_floor = 0` 写死，注释说「authored MIN/MAX 已经界定了采样」——
**但如果采样是原始 metric 而没有经过 MIN，那个假设就不成立**，派生层会给出远超卡片设计上限的值。

**B 若成立是严重缺陷**：一张本来封顶 15.0 的卡会在派生路径上输出 120.0。

## 5. 我为什么停在这里

区分 A 与 B 需要确认 `metric_keys` 里 index 57 对应哪个 `FamilyEffectMetricId`，
这需要读编译产物的 metric 表。本轮已用尽预算，且**在没区分之前继续调测试会污染结论**。

## 6. 顺带修正的一处

第一版我用 `economy.city.output_factor` 作 stat，测到 `derived_add = 0`。
真实值是 `economy.city.building.extractive_output_factor`（读自卡片自己的 `command.definition_key`）。
**猜 stat 名浪费了一轮**——应当一开始就从定义里读。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_oracle_cross_check_test.gd` | 对照夹具（6 checks，**当前 1 失败**）|

**它现在是一个失败的测试，不是通过的证据。** 保留它是因为两侧测量都已打通，
只差槽位映射的确认。

## 8. 下一步（明确）

1. 从编译产物的 `metric_keys` 取 index 57 对应的 FamilyEffectMetricId；
2. 用**同一个** metric 驱动两侧，重跑对照；
3. 若仍不一致，则 B 成立，需要在收集器里补 MIN/MAX 边界（`ramp_has_ceil` / `ramp_floor`）。
