# M3-23 修正探针桥的缺陷；判定器本身正确

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | `probe backend=DerivedCell`（修正后）；`seen=0` 仍在 |
| 结论 | 判定器正确，缺陷在**我写的探针桥** |

## 1. 找到了我自己的一个缺陷

M2-19 我写的 `probe_cell_program_backend` 桥（`world_ext_modifier.cpp:795-808`）
构造 `CellProgramCommandFacts` 时**漏了 `has_metric_ramp`**：

```cpp
// 改前：has_metric_ramp 保持默认 false
command.stacks = ...;
command.duration_days = ...;
parsed.commands.push_back(command);

// 改后
command.has_metric_ramp = bool(facts.get("command_has_metric_ramp", false));
```

**后果**：所有 ramp 探针都返回 `non_constant_value_mode`（拒绝），无论真实运行时怎么判定。
我在 M3-22 把这个错误结果当成了「判定器有问题」的证据，方向完全错了。

修正后：

```
[q] probe backend=DerivedCell reason= detail=derived
```

**判定器一直是对的。**

## 2. 这解释了 M3-22 的困惑

M3-22 我记录：

> `backend=EffectInstance reason=non_constant_value_mode` → 判定器说「既非常数也非 ramp」

**真相是我的桥没传这个字段。** 判定器收到 `has_metric_ramp=false` 后给出那个结论完全正确。

## 3. 但 `seen=0` 仍未解决

```
[q] ACTIVE!
[q] probe backend=DerivedCell
[q] ramp_samples_taken=0 evaluated=0
[q] materialise seen=0
```

判定说 DerivedCell、理念 ACTIVE、重建在跑（`visits=5`）、程序确实存在
（`ideology.effect.salt_monopoly_l1 -> ok=true`）——**四个条件都满足，但 `seen=0`。**

所以 `collect_effect_activations` 一定在 **`probe_cell_program_backend` 之外**的环节退出。
剩余可能（`ideology_runtime.cpp:2159-2190`）：

| 行 | 条件 | 状态 |
|---|---|---|
| `:2159` | `ideology_id` 越界 | 不太可能（dense=87 有效）|
| `:2162` | `location == INACTIVE` | 已排除（`locations=[1]`）|
| `:2165` | `level >= level_count` | 已排除（试过 level 0 和 2）|
| `:2167` | `copy_left_programs != 0` 走 copier 分支 | **未查** |
| `:2174` | `row.persistent_count == 0` | 数据看应为 2，但未实测 |
| `:2182` | `program.empty()` | 已排除（`definition_key` 非空）|
| `:2184` | `family_effect_metadata_pod` 返回 false | **程序存在，但 metadata_pod 可能仍失败** |

**`:2174` 与 `:2184` 是两个未查的点。**

## 4. 本轮验证

| 项 | 值 |
|---|---|
| 桥的 `has_metric_ramp` | **已修**（这是我自己的缺陷）|
| `probe backend` | **`DerivedCell`** |
| 理念 ACTIVE | ✅ |
| 程序存在性 | ✅ `ok=true` |
| `seen` / `taken` | 0 / 0 |
| 构建 | exit 0 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 5. 局限

- **仍未取得 ramp 真实幅度。**
- `:2174` / `:2184` 未实测。
- 修正桥之后，M2-19 那个 catalog 测试的断言前提也变了（它当时断言 DerivedCell 且通过，
  说明那条用例传了别的字段组合）——未复核。

## 6. 一条值得记的教训

**我自己的诊断工具错了两次**：
1. `filled=10 of 10` 只检查 `sid >= 0`，没验证写入成功（M3-20）；
2. `probe_cell_program_backend` 漏传 `has_metric_ramp`（本轮）。

两次都让「工具报告的结果」与「真实状态」脱节，并把调查引向错误方向。
**当诊断工具本身没有负向对照时，它可能比没有工具更糟。**
