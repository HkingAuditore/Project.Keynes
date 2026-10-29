# M3-2 逐格 ramp 求值器 — 打通

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `run_program_machine`（VM 抽取）、`evaluate_program_magnitude_for_metrics`、`evaluate_effect_program_magnitude` 桥、`ideology_cell_layer_ramp_test.gd` |
| 结果 | **13 checks, 0 failures** |
| 结论 | ramp 不再是「未支持」——它能按 metric 求值，且实测随输入线性变化并在上限饱和 |

## 1. 核心问题与解法

M1/M2 只能处理常数幅度，所以 24 个 Ramp program 被 `ramp_not_yet_supported` 排除。把 ramp 折叠成常数是 §15.5 明令禁止的（幅度会随时过期）。

**解法：让同一条 VM 跑在调用方提供的 metric 采样上，而不是重写求值器。**

```cpp
// 改前
bool preview_family_effect_value(definition, instance, value, error)
    // 内部: stack[sp++] = metric_value(instance, row.arg0);

// 改后
bool run_program_machine(definition, metric_accessor, state_accessor, value, error)
    // 内部: stack[sp++] = metric_accessor(row.arg0);
bool preview_family_effect_value(...)     // 绑定 instance 后委托
bool evaluate_program_magnitude_for_metrics(program, metrics, ...)  // 绑定采样后委托
```

**关键决定：抽取而非复制。** 指令集是 ADD/SUB/MUL_Q16/DIV_FLOOR/MIN/MAX/CLAMP/EMIT_COMMAND 的栈机，第二份实现会成为又一个必须同步的地方，而简化版必然退化成「冻结成阈值桶」——正是 §15.5 禁止的。

## 2. 一次被自己否决的实现

首版用 `const_cast` 临时替换 `_metric_values` 来喂采样。**这在 worker 路径下是数据竞争**（方案 §8.1 禁止）。

改成参数化访问器后，`evaluate_program_magnitude_for_metrics` **不修改任何运行时状态**，注释里也写明了原因。

## 3. 实测数据

对真实内容 `ideology.effect.salt_monopoly_l1`（metric 57 = `country.extractive_cell_count`）：

| metric | 幅度 |
|---:|---:|
| 0 | 0 |
| 2 | 1310 |
| 5 | 3275 |
| 10 | 6550 |
| 1000 | **9825**（饱和）|
| 100000 | **9825**（同值）|

即 `min(metric, 15) × 655/65536`。

## 4. 两处我自己的错误

### 4.1 程序键要带域前缀

首版用 `salt_monopoly_l1`，得到 `effect_program_not_found`。编译后的键是 `ideology.effect.salt_monopoly_l1`。

### 4.2 用错了档位的常数

我按 `.tres` 里读到的 `CONST(983)` / `CONST(655360)` 推出「上限 10 单位」，断言 metric=10 与 1000 应相等。**实测 1000 给出 9825 = 15×655，说明上限是 15 单位、scale 是 655。**

原因：我读的是 `ProgSaltMonopolyL2Ramp*` 的常数，却当成 L1 的用。**各档位的 scale 不同。**

修正后的断言不再写死常数，而是断言**实测行为**：饱和值大于 linear 前一点、远小于线性外推（65500）、且对 1000 倍与 100000 倍输入给出同一值。

## 5. 验证

| 项 | 值 |
|---|---|
| ramp 测试 | **13 checks, 0 failures** |
| 覆盖 | A 能求值 / B 随 metric 单调 / C 单调性 / D 双向饱和 / E 无关 metric 不影响 / F 未知程序报错 |
| 纯核门禁 | oracle 735 / materializer 65 / eligibility 56 / cap_removed 12 全 0 |

## 6. 仍未完成的 M3 部分

| 项 | 状态 |
|---|---|
| 逐格求值器 | ✅ |
| `collect_effect_activations` 生成 ramp term | ❌ 未接 |
| 物化器的 metric 采样接线 | ❌ 未接 |
| 国家级 metric 的每国一次优化 | ❌ 未设计 |
| M3 的 6 个退出条件 | 🟡 1/6（ramp 随输入变化）已验证 |

**M3 退出条件「同国不同格的 ramp 数值不同且正确」尚未验证**，因为那需要把逐格采样接进物化器，而采样依赖经济的逐格状态。

## 7. 局限

- 只测了 `salt_monopoly_l1` 一条；24 个 ramp 的其他 23 条未逐一验证。
- 未测单国不同格（需要真实经济状态）。
- 未测 `READ_STATE` 路径（派生层传 0 accessor，而 STATE 程序本就不是 DerivedCell）。
- `evaluate_effect_program_magnitude` 桥的 `metric_values` 长度由调用方保证；越界读 0。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_ramp_test.gd'
# => 13 checks, 0 failures
#    [ramp] metric=2 -> 1310, metric=10 -> 6550, metric=1000 -> 9825 (饱和)
```
