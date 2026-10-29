# M2-16 value_mode 硬编码修复 + 2000 格分布

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §4.4 条件 4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ProgramModifierCommand.value_mode` 字段 + 判定器改用真实值；2000 格 4 样本分布 |
| 结果 | 覆盖率 **241/47 完全不变**；2000 格每格 **5.99 us**，与 800 格 5.65 us 一致 |
| 结论 | 修复了一个**会静默误判未来内容**的缺陷，且零行为变化 |

## 1. 修的是什么

`cell_program_facts_for` 里这一行：

```cpp
row.value_mode = 1;  // every shipped city command uses stack-top
```

注释本身是诚实的——**当前**内容确实都用栈顶。但 §4.4 条件 4 的判定依赖这个字段：

```cpp
// cell_program_eligibility.h:296-297
command.value_mode == 0 ||                      // VALUE_CONSTANT：可以派生
(command.value_mode == 1 && command.stack_top_is_constant)   // VALUE_STACK_TOP：栈顶是常数才行
```

硬编码成 1 意味着**任何将来写 `VALUE_CONSTANT`（=0）的卡都会被当作「栈顶」来判断**。它恰好也能通过（只要栈顶是常数），但判断依据错了——而错的那一天不会有任何报错。

## 2. 为什么能修

真正的原因不在判定器，而在接口：

```cpp
// 改前
struct ProgramModifierCommand {
    std::string definition_key;
    int64_t value_q16 = 0;
    int32_t stacks = 1;
    int32_t duration_days = -1;
};   // ← 没有 value_mode
```

而 `program_modifier_commands` 是从完整的 `CommandDefinition` 里构造它的，那个结构**有** `value_mode`（`effect_runtime.h:761`），只是被丢弃了：

```cpp
out.push_back(ProgramModifierCommand{command.definition_key,
    command.value, command.stacks, command.duration_days});   // ← value_mode 丢掉
```

所以这是**一个字段的传递缺口**，不是设计限制。

## 3. 改法

| 位置 | 改动 |
|---|---|
| `effect_runtime.h` | `ProgramModifierCommand` 增加 `int32_t value_mode = VALUE_STACK_TOP;` |
| `effect_runtime.cpp` | 构造时传入 `command.value_mode` |
| `ideology_runtime.cpp` | `row.value_mode = command.value_mode;` |

## 4. 零行为变化的证据

改完后覆盖率报告：

```
programs: 288
  DerivedCell   : 241
  EffectInstance: 47
    24  ramp_not_yet_supported
    16  not_cell_domain
     5  unsupported_selector
     2  stacked
```

**与修改前逐项相同。** 原因很直接：194 个 content 全写 `value_mode = 1`（`VALUE_STACK_TOP`），所以硬编码 1 与真实值一致，改动对现有内容不可见。

这正是我想要的结果：**修掉一个对当前无害、对未来有害的缺陷，而不改变任何现有行为。**

## 5. 2000 格分布（本轮同时完成）

```
[runs] run 1: 12.929 ms over 32 slices / 2000 cells
[runs] run 2: 14.750 ms over 32 slices / 2000 cells
[runs] run 3: 11.035 ms over 32 slices / 2000 cells
[runs] run 4: no reading (economy fatal)
[runs] run 5:  8.166 ms over 32 slices / 2000 cells

n=4  min=8.166  p50=11.982  max=14.750 ms
us/cell at p50 = 5.991
spread max/min = 1.81x
```

**分片数 4/4 次都是 32 = ⌈2000/64⌉。**

## 6. 线性度：两个规模互相印证

| 格数 | n | 分片数 | p50 ms | us/cell (p50) | 离散度 |
|---:|---:|---:|---:|---:|---:|
| 800 | 5 | 13 | 4.516 | **5.65** | 1.69x |
| 2000 | 4 | 32 | 11.982 | **5.99** | 1.81x |

**每格成本差 6%**，跨 2.5 倍覆盖范围。线性模型成立。

而且两者都收敛到 M2-6 假设的 **6.0 us** 附近——这是第三次独立验证同一个常数。

## 7. §14.3 门禁重判（用 2000 格 p50）

```
每片 city 因子  11.982 / 32 = 0.374 ms
+ epoch-open 其他            0.465 ms
= 0.841 ms  <  1.0 ms        余量 15.9%
```

与 800 格算出的 0.812 ms 几乎相同（因为每片工作量固定 64 格）。**门禁通过。**

## 8. 局限

- **`spread` 1.69x / 1.81x 说明单次读数仍不可信**，必须用 p50 而非任一次采样。
- 2000 格只有 n=4（一次 fatal 丢掉一个样本）。
- 两个规模的 p95 在 n<20 时按 nearest-rank 等于 max，不是真正的 p95。
- 6400 格仍是外推（按 5.99 us/格 = 38.3 ms）。
- ~~回归正在运行~~ **已完成：changed verdicts = 0**（15 fixture 逐项与 M0 基线一致，含失败项）。DLL `5f59339e…`。

## 9. 复算方式

```powershell
python Project/project-keynes/tools/ideology/measure_city_factor_runs.py --cells 2000 --runs 5
# => n=4 p50=11.982 us/cell=5.991 spread=1.81x
```
