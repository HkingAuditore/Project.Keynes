# M5-47 kind 14 诊断：新增的 key 级诊断排除了两个猜想，但根因仍未找到

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-46](M5-46-batch-dilation-replaces-per-source.md) 的「端到端夹具缺失」 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **根因仍未找到**；排除两个猜想；**并阻止了一次错误的"修复"** |

## 1. 新增的诊断

`collect_pod_fail` 只是个计数，无法区分「卡没进 active 列表」与「卡在 active 但声明式 program 缺失」。
这个歧义已经耗掉两轮（M5-34、M5-40）。所以新增：

```cpp
// 导出前 8 个 POD 解析失败的 program key
out["collect_pod_fail_keys"] = <PackedStringArray>
```

在采集阶段每次 `family_effect_metadata_pod` 失败时记录，采集开始时清空。

## 2. 它给出了什么

```
[diag] templates=8 pod_fail=4 program_empty=0 targets_fail=4 entries=4
[diag] pod_fail_keys=["ideology.effect.ideology.autonomous_logistics"]
[diag] does the CARD's program appear among the failures? false
```

**program key 被双重加了 `ideology.` 前缀。**

## 3. 猜想一（错误）：`effect_program_key` 双重前缀是真 bug

`effect_program_key` 的实现就是无条件拼接：

```cpp
return "ideology.effect." + definition_key;   // :1737
```

所以我一度认为：只要 `definition_key` 自带 `ideology.`，program 就永远解析不到。

**但看内容结构就推翻了**：

```
[sub_resource id="EffectAutonomousLogisticsCostL1"]
action = 1                     # ← COST，不是效果
domain = 1
value_q16 = 65536
command_key = &"ideology.persistent"
definition_key = &"ideology.autonomous_logistics"     # ← 这一条
```

**这是一条「成本」条目。** 成本没有声明式 program，`family_effect_metadata_pod` 对它失败是**正确的**。
`pod_fail_keys` 命中的正是它，不是卡片的效果程序。

**所以我没有动 `effect_program_key`，也没有动那个 key。**

## 4. 猜想二（错误）：3 张卡引用了卡片级 key，效果程序从未被使用

我进一步以为：`ideology.autonomous_logistics` 是卡片级 key，而真正的效果
`autonomous_logistics_l1/l2/l3` 从未被引用。

**同样被结构推翻**：`persistent_effects` 是数组，成本之外还有真正的效果条目：

```
persistent_effects = Array[Resource]([
    SubResource("EffectAutonomousLogisticsCostL1"),   # 成本
    SubResource("EffectAutonomousLogisticsL1R0")])    # ← 真正的效果
```

`autonomous_logistics_l1/l2/l3` 在效果文件里**确实存在**，也**确实被引用**。

**我准备好的「把 catalog 里 3 处 key 改成 level 对应的效果 key」这个修复是错的，没有执行。**
如果执行了，会把成本条目的 key 改掉，破坏成本。

## 5. 所以现在知道什么、不知道什么

| 已知 | 未知 |
|---|---|
| `pod_fail_keys` 能指名失败的 program | **`covered=0` 的真正原因** |
| 命中的是**成本条目**，其失败是正常的 | 卡的真实效果条目是否解析成功 |
| `autonomous_logistics_l1/l2/l3` 在效果文件里存在且被引用 | 若解析成功，为什么没有派生贡献 |
| 卡确实装备成功（`applied=4 rejected=0 active=1 locations=[1]`）| — |

**根因仍未找到。** 四轮尝试分别卡在：原生 tag（错）、POD 计数不可区分（对，但不足）、
双重前缀（错）、卡片级 key（错）。

## 6. 一个值得记下的模式

**我的第一遍读代码/数据，四次都不完整。**

前三次是「读注释」「读数据文件」「读字符串匹配」，这一次是「只看命中行、不看它所在的资源块」。
共同点：**我看到一个局部事实就当成全貌**，而没有先确认那个事实所处的结构。

具体到这次：`definition_key = &"ideology.autonomous_logistics"` 单独看像是「卡片的错误引用」，
放在 `[sub_resource id="...CostL1"]` 里才是「成本条目的定义」。

**一个仍然有效的做法：先确认容器，再看字段。**

## 6.1 决定性的一步：同时记录「成功」的 key

只记失败是不够的——**成本条目本来就该失败**，所以「有失败」什么也证明不了。
加上成功列表后：

```
[diag] pod_fail_keys=["ideology.effect.ideology.autonomous_logistics"]   <- 成本条目
[diag] pod_ok_keys  =["ideology.effect.autonomous_logistics_l1"]          <- 卡的真实效果
[diag] derived_emitted=0  targets_fail=4
```

**结论：POD 层是好的。** 卡的效果程序 `ideology.effect.autonomous_logistics_l1`
**解析成功**，所以之前「program 找不到」这条线彻底排除。

**失败在下一层：目标解析。** `targets_fail=4` 且 `own_*` 诊断字段全未运行，
说明 kind 14 的 `OWN_TERRITORY` 取源格这一步没有执行到。

这把范围从「三层（POD ／ 资格 ／ 目标）」缩到 **只剩目标解析一层**。

## 6.3 目标层的五个计数器全是 0 —— 连同我另一个错误推断

```
[diag] targets: no_tag=0 empty=0 domain_gate=0 economy_null=0 country_zero=0
```

`resolve_effect_targets` 在这些前置门上**一次都没有退出**：

| 计数器 | 含义 | 值 |
|---|---|---|
| `targets_fanout_no_tag` | kind 14/15 的 `tag <= 0` 早退（本轮新增）| **0** |
| `targets_collected_empty` | 解析完却为空 | 0 |
| `targets_domain_gate` / `economy_null` / `country_zero` | 其它前置门 | 0 |

**并且我要更正上一轮的一个判断。** 我说过「`own_*` 全未运行，说明取源格那一步没执行」——
那是**查错字段**：`own_*` 在 `get_economy_territory_plane()` 的返回里，不在 `get_ideology_report()` 里。
B7 打印它们用的是前者而我没注意。**所以「ONW 分支未运行」这个结论是错的，我撤回它。**

## 6.4 现在最可能的剩余原因

`targets_fail=4` 且前置门计数全 0，剩下两个未计数的出口：

1. `collect_effect_target_cells(anchor, OWN_TERRITORY, …)` 之后 **`if (sources.empty()) return false;`**
   —— 这一句**没有计数器**。
2. `resolve_effect_targets` 更早处的某条 `return false`（例如 metadata/资格相关）。

若原因是 1，则含义是：**tag 扫描没有匹配到任何格**，也就是说
`set_effect_metric_override_for_test(cell.trade_events)` **没有影响到 tag 快照**。
那是一个夹具层面的问题（tag 快照在采集时构建，override 可能早于/晚于它），不是产品缺陷。

**下一步只需给 `sources.empty()` 那一句加一个计数器**，就能一次判定。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/ideology_runtime.h/.cpp` | `_collect_pod_fail_keys` + 导出 `collect_pod_fail_keys` |
| `tests/ideology/ideology_kind14_diagnosis_test.gd` | 3 checks / 0，打印诊断 |

## 8. 下一步（明确）

1. 在诊断夹具里打印 **`EffectAutonomousLogisticsL1R0` 那条效果**的 `definition_key`，
   确认它是否解析成 `ideology.effect.autonomous_logistics_l1`；
2. 若解析成功而仍无派生贡献，问题在**资格判定**而非 POD；
3. 若解析失败，再查那一类效果条目的 key 形态。

**第 1 步只需要多一个打印，不值得再猜。**
