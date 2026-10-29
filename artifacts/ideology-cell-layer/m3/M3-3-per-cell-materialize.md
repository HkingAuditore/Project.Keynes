# M3-3 物化器逐格求值 — 「同国不同格」条件达成

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 退出条件 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | ramp term 生成、物化器逐格求值分支、`build_derived_cell_front_for_test` 桥、12 checks 测试 |
| 结果 | **12 checks, 0 failures** |
| 结论 | **「同国不同格的 ramp 数值不同且正确」首次直接验证** |

## 1. 决定性证据

```
[ramp-mat] per-cell values = [3.0, 5.0, 7.0]
[ramp-mat] ramp_terms_evaluated = 3
```

三个格得到三个**不同**的值，且每个都等于独立计算的 `sample(cell) × scale`。

这正是 §15.5 的退出条件，也是 M1/M2 无法证明的那一条。

## 2. 接线分三处

### 2.1 生成 ramp term（`ideology_runtime.cpp`）

```cpp
// 之前：一律用常数幅度
const int64_t magnitude = clamp(command.value_q16, 0, MAX);

// 现在：ramp 时记录 metric 与 scale，幅度留给物化器
const bool ramp = command.value_mode != VALUE_CONSTANT &&
                  metadata.metric_mask.is_any();
row.magnitude_source = MagnitudeSource::RampMetric;
row.metric_id = ramp_metric_id;
row.ramp_scale = term.value * stacks / Q16_ONE;
row.add = 0.0;  row.factor = 1.0;
```

判定条件必须是**两个同时成立**：
- `value_mode != VALUE_CONSTANT` —— 否则只是栈顶命令，与 metric 无关；
- `metric_mask.is_any()` —— 否则可能是条件读 metric 而幅度是常数。

只满足其一都会误判。

### 2.2 物化器逐格求值（`derived_cell_materializer.cpp`）

```cpp
if (term.magnitude_source == RampMetric) {
    if (out_ramp_sampler == nullptr || term.metric_id < 0) {
        ++out_report.ramp_terms_deferred;
        continue;           // 不折叠成 0
    }
    const double sampled = (*out_ramp_sampler)(term.metric_id, cell);
    ++out_report.ramp_terms_evaluated;
    const double magnitude = evaluate_ramp_magnitude(term, sampled);
    ...
}
```

### 2.3 采样器通过 options 传入，不破坏既有签名

```cpp
using DerivedRampSampler = std::function<double(int32_t, int32_t)>;
struct DerivedMaterializeOptions { const DerivedRampSampler *ramp_sampler = nullptr; };
```

**10 参数形态保留为主签名**，内部委托给 11 参数重载。这样既有 735 个 oracle 检查、65 个物化器检查全部零改动通过。

## 3. 一个必须说明的设计决定：无采样器时「延迟」而非「归零」

如果拿不到 metric，有两条路：

| 方案 | 后果 |
|---|---|
| 折叠成 0 | 效果**静默消失**，没有任何信号 |
| 记入 `ramp_terms_deferred` 并跳过 | 效果不生效，但**计数可见** |

我选了后者。**静默归零是最难诊断的一类 bug**——效果没了，日志干净，数字合理。

测试 C 组专门断言这一点：`ramp_terms_deferred > 0` 且该格贡献为 0。

## 4. 六组断言

| 组 | 内容 |
|---|---|
| A | 物化器真的执行了逐格求值（`ramp_terms_evaluated > 0`），且**三格三值** |
| B | 每格值 == `sample(cell) × scale`，独立计算比对 |
| C | 无采样器时**延迟**而非归零 |
| D | 常数项与 ramp 项在同格共存（0.25 + 6.0 = 6.25）|
| F | 40 格 ramp 不截断，`truncated == 0` |

## 5. 测试为什么用合成采样器

生产路径需要活的 epoch 才能产出 metric 采样，而那个夹具缺口已阻挡端到端验证五次（M1-8/1-13/M2-9/M2-14/M2-17）。

**用合成采样器可以验证物化器的逐格分支本身**——这正是 M3 退出条件问的问题。

但它证明不了：真实经济状态下 `sample_effect_metrics` 的返回值是否合理。这一点仍未验证。

## 6. 验证

| 项 | 值 |
|---|---|
| ramp_mat 测试 | **12 checks, 0 failures** |
| ramp 求值器 | 13 checks（M3-2）|
| 纯核门禁 | oracle 735 / materializer 65 / eligibility 56 / cap_removed 12 / ceiling 35 全 0 |
| 覆盖率 | 6/6 |

## 7. M3 剩余

| 项 | 状态 |
|---|---|
| 逐格求值器 | ✅ |
| ramp term 生成 | ✅ |
| 物化器逐格求值 | ✅ |
| 同国不同格数值不同 | ✅ **已验证** |
| 国家级 metric 的每国一次优化 | ❌ 未做（当前每格都采样，正确但非最优）|
| 阈值不变但 ramp 输入变化仍刷新 | ❌ 未验证 |
| 条件边界与反向失效 | ❌ 未验证（M3 的 D=41 部分）|
| 更新成本与 B9 预算 | ❌ 未测 |
| save 冻结源与消费黄金测试 | ❌ 未做 |

**M3 的 C 类（ramp）已打通，D 类（41 个条件常数）尚未开始。**

## 8. 局限

- 只测通 1 条真实 ramp（`salt_monopoly_l1`），其余 23 条未逐一验证。
- 未验证真实 `sample_effect_metrics` 的取值。
- 国家级 metric 当前**每格重复采样**；结果正确，但 1000 格 × 国家级 metric 会有冗余计算，性能影响未测。
- `build_derived_cell_front_for_test` 是测试专用桥，不在生产路径上。
- D 类（条件常数）完全未动。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_ramp_materialize_test.gd'
# => 12 checks, 0 failures
#    [ramp-mat] per-cell values=[3.0, 5.0, 7.0]
```
