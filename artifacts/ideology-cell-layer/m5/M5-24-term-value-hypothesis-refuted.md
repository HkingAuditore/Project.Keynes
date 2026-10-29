# M5-24 排除「term.value 双重计数」假设 + 锁定符号机制

| 项目 | 内容 |
|---|---|
| 里程碑 | [§13.1 第 2 层](22-cell-program-cap-removal-plan-v3.md) / §18.1 数值正确性 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **假设被排除**（不是 bug）；顺带**端到端锁定「-8% 卡不会变 +8%」** |
| 验证 | B7 **23 checks / 0 failures** |

## 1. 为什么怀疑

派生收集器对常数项：

```cpp
row.add    = term.operation == ADD ? term.value * stacks * scaled_magnitude : 0.0;
row.factor = term.operation == ADD ? 1.0 : std::pow(term.value, stacks);
```

- 幅度来自**程序**（`scaled_magnitude`）
- 又乘了**定义的系数** `term.value`

**如果 `term.value != 1`，同一个效果会被算两遍。** 这正是 ramp 那个 bug 的同族问题
（两个来源都在给幅度），值得系统排查。

## 2. 静态扫描的结果（差点误判）

直接解析 `default_modifier_catalog.tres`，按 `definition_key` 找定义，得到：

```
definitions whose value != 1 (6):
   op=2 value=0.970000  economy.city.birth_factor
   op=2 value=1.050000  economy.city.need.clothing.consumption_factor
   op=2 value=1.050000  economy.city.need.home_energy.consumption_factor
   op=2 value=1.050000  economy.city.need.household_goods.consumption_factor
   op=2 value=1.050000  economy.city.need.housing.consumption_factor
   op=2 value=1.080000  economy.city.need.luxury.consumption_factor
```

**看起来 `public_hygiene_l1` 就在其中**（它命令 `economy.city.birth_factor`），
而且 `op=2` 是 MULTIPLY，那样 `row.factor = pow(0.97, 1) = 0.97` 且**程序幅度被完全忽略**。

如果这是真的，是又一个严重缺陷。

## 3. 但静态扫描是错的，解析器才是权威

`resolve_modifier_definition_terms()` 的实测输出：

```
economy.city.birth_factor                          -> [{ stat_id: 10,  operation: 0, value: 1.0 }]
economy.city.need.housing.consumption_factor       -> [{ stat_id: 85,  operation: 0, value: 1.0 }]
economy.city.need.housing.consumption_factor.cut   -> [{ stat_id: 85,  operation: 0, value: -1.0 }]
economy.city.good.adobe_brick.output_factor        -> [{ stat_id: 230, operation: 0, value: 1.0 }]
```

| 项 | 静态扫描说的 | **解析器说的（权威）** |
|---|---|---|
| operation | `2`（MULTIPLY）| **`0`（ADD）** |
| value | `0.97` | **`1.0`** |

**我解析 `.tres` 时读的是另一组字段**（`default_value` 一类），不是卡面真正解析出的 term。

**结论：`term.value` 对 cell 卡恒为 ±1，`term.value * magnitude` 不是双重计数。假设排除。**

## 4. 顺带确认了一件更重要的事：符号来自定义

`.cut` 变体的 `value` 是 **`-1.0`**，而程序对两个命令发的都是**正幅度**。
所以「-8% 变 +8%」只能靠 `term.value` 这个负号来避免——而它此前没有任何端到端断言。

B7 新增：

```
[B7] cut card: { "value": 0.91999816894531, "derived_add": -0.08000183105469,
                 "derived_factor": 1.0, "derived_present": true }
```

| 观察 | 含义 |
|---|---|
| `derived_add = -0.08000183105469` | 程序发的 `5243/65536 = 0.0800` 被 `term.value=-1` 变成**负** |
| `value = 0.92` | 基准 1.0 + (-0.08) —— 加法语义正确 |
| `derived_factor = 1.0` | 没有被误当成乘法 |

**「-8% 卡」端到端正确。** 这条断言现在会挡住那类静默翻符号的回归。

## 5. 我这次差点犯的错

静态扫描给出「6 个定义的 value 不是 1，其中包含 `public_hygiene` 用的 key」时，
**很容易直接写成「发现新 bug」**。

是解析器（权威实现）把结论推翻了。教训与 ramp 那次相反相成：

- ramp 那次：**不要相信注释**说的「已经界定」；
- 这次：**不要相信自己对数据文件的解析**。

两者共同的正确做法是**问权威实现**，而不是读二手材料。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_b7_wide_territory_test.gd` | 新增 `.cut` 负号断言，**23 checks / 0** |
| 本报告 | 假设排除过程与符号机制的端到端证据 |
