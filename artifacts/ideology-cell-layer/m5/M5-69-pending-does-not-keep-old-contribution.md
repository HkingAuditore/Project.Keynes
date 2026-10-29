# M5-69 数值证据：pending **不**保留旧贡献，拒绝在 Modifier 域**留下残留**

| 项目 | 内容 |
|---|---|
| 夹具 | `ideology_pending_keeps_old_contribution_test.gd` — **140 / 0**（我独立复跑确认）|
| 覆盖 | §18.1「pending 保留旧贡献、拒绝无残留、一次性效果不重放」的**数值侧** |
| 结论 | **三个子项里只有「一次性不重放」成立** |
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 【缺陷 1】pending 时不保留旧贡献 —— 直接读到新值

`idea.public_hygiene` 升级（L1 → L2），在 `pending_transitions == 1`、**未做 ack 握手之前**读逐格值：

| 状态 | 逐格 add | 逐格 .cut | front cells | contributions |
|---|---|---|---|---|
| L1 已结算（基线）| `0.05000305`（+3277/Q16）| `−0.08000183`（−5243/Q16）| 84 | 84 |
| **L2 PENDING（未 ACK）** | **`0.08000183`（+5243/Q16）** | **`−0.10000610`（−6554/Q16）** | 84 | 84 |
| L2 已结算 | `0.08000183` | `−0.10000610` | 84 | 84 |

**pending 时卡片已经在服务 L2 的值——既不是旧值，也不是「没有」。**

而 `transition_transaction_statuses == [1, 1]`（都是 PLANNED，**一个都没 ACK**），`state.levels == [1]` 在**请求时**就已经写好了。

### 根因（两半互相矛盾）

| 位置 | 行为 |
|---|---|
| `collect_effect_activations` `:2285` | 只判 `location != INACTIVE && level >= 0`，**从不读 `transition.active`** |
| `start_transition` `:3598` | 在**请求时**就写 `state.level = target` |
| **日常理解度累积** `:5006` | **读了** `transition.active` 并保留 `previous_level` |

**同一张卡的两半对「转移在飞时该用哪个等级」给出了相反答案。**

### 为什么内容检查看不出来

**结算不改变任何东西**——pending 值与结算值完全相同（夹具专门断言了这一点，`A3 settle [OUTCOME B]`）。
所以「先看卡、再结算、再看卡」的检查永远发现不了这个泄漏。

## 2. 【缺陷 2】拒绝在 Modifier 域留下残留

派生层是**干净的**（这部分我逐项核过）：

| 断言 | 结果 |
|---|---|
| `contribution_count` 回到转移前的精确值 | ✅ 84（升级）／**0**（被拒装备）|
| 行数没有翻倍 | ✅ 84，不是 168 |
| 64 格上没有任何孤儿贡献 | ✅ |
| 槽位释放、卡片回 INACTIVE | ✅ |
| 经济审计 0/0/0 | ✅ |

**但 Modifier 域不干净**：

```
[FINDING] the rejected transition left 1 COUNTRY-domain modifier row(s) behind: ["ideology.standardization"]
[FINDING] the rejected EQUIP left 1 COUNTRY-domain modifier row(s) behind: ["ideology.public_hygiene"]
```

**第二条最刺眼**：卡片已经 INACTIVE、cell 贡献 0 行，**而它的成本行 `ideology.public_hygiene` 还在**——
**这是毫无歧义的孤儿。**

### 机制

`run_modifier_daily` 按提交顺序**逐行应用**，直到走到失败的那一行才让 ACK 报拒绝；
而 `apply_rejected_instance_transition` **从不回滚已经提交的行**。

## 3. 【缺陷 3】被拒的升级会在**同一个 slice 内重试**

slice 顺序是 poll（回滚）→ commands → active progress（`:4918-5035`, `:5022`）。
回滚恢复了 `previous_level`，但理解度**仍然超过 L2 阈值**，所以 `start_next_level_transition` 立刻重新打开它、
并再次写 `state.level = target`。

实测：`levels_advanced 2 → 3`、`pending_transitions == 1`、`levels == [1]` 在回滚当天结束时。

**后果**：两次回滚之间，派生层**从不显示被回滚的值**。所以「无残留」在升级路径上只能测到「没有累积」，
测不到「回退可见」——夹具因此用 world C（装备，没有任何东西会重试它）来承载可见的回退。

**一张永久失败的转移会每隔一天重新发出它的批次，并持续服务目标等级的幅度。**

## 4. ✅ 成立的子项：一次性效果不重放

| 时点 | 发射次数 |
|---|---|
| 升级前 | 0 |
| pending（未 ACK）| **1** |
| ACK 后 | 0 在飞 |
| 之后两天 | **0** 新增 |
| **跨边界总计** | **1** |

且 Modifier store 在结算后与两天后**都恰好只有 1 行**已应用的 `ideology.standardization`。

## 5. 我做了什么、没做什么

| 做 | 没做 |
|---|---|
| 复跑确认 140/0，亲眼看到三条 FINDING | **没有修 `collect_effect_activations`** |
| 把三个缺陷的机制逐行核实 | 没有改 `apply_rejected_instance_transition` |
| 夹具**只断言残留的「受限形状」**（只允许来自被拒批次、不允许外来定义），**不断言方案的承诺** | 没有压制「同 slice 重试」（负向 `ADD_UNDERSTANDING` 被队列拒绝）|

### 为什么不修

**修 `collect_effect_activations` 加一个 `transition.active == 0` 的门，会改变多个夹具的行为**——
B1／B3／B7 都在装备后读派生层。它们都做了 ack 握手，所以结算后不受影响；
但**任何在 ack 之前读层的夹具都会看到 0**，而 `equip()` 立刻写 `location` 正是它们依赖的行为。

**而如果这个门加错，21 个夹具会全绿而语义已变**——比留一个已记录的缺陷更危险。

**这是产品语义决策**（`equip()` 该不该立刻生效），和 D1–D4 同类，应由用户定。

## 6. 这两条的建议修法（写清但不执行）

| 缺陷 | 建议修法 |
|---|---|
| pending 贡献 | `collect_effect_activations` 按 `:5006` 的方式读 `transition.active` 与 `previous_level`；**同时**要让 `equip()` 的可见性语义明确（立即 vs ACK 后）|
| 拒绝残留 | `ack_native_modifier` 拒绝时，必须回滚该批次**已提交**的行——或者干脆先全量校验再提交 |

## 7. 交付物

| 文件 | 检查数 |
|---|---:|
| `tests/ideology/ideology_pending_keeps_old_contribution_test.gd` | **140 / 0**（含三条 `[FINDING]`）|
| `tools/ideology/verify_delivery.py` | 检查数已入表 |

## 8. 局限

- **升级回滚后的「回退可见」测不到**：运行时在同 slice 重试，且负向 `ADD_UNDERSTANDING` 被拒（`ideology_value_negative`）。用 world C（装备）替代，对「无残留」这个断言其实**更强**。
- **被拒升级后残留的 `ideology.public_hygiene` 是 L1 还是 L2 无法区分**：两个等级授权同一个 definition key 与同一个 65536 幅度，只有内部 `source_id` 不同，而 `list_modifiers` 不暴露来源等级。
- **`free_draw` 那种玩法型一次性未测**（出厂唯一非空 on-enter 是 `idea.civil_examination` L3，需要 gameplay 适配器）。
- 全部主线程无头，**未走 worker 权威路径**。
