# 随军人口实现契约（v1）

> 2026-11-03。目标：士兵随部队移动，在部队所在地消费（客籍消费），口粮按部队位置供应。
> 设计依据 `docs/plans/military-system-design.md` §5.7；本文只冻结实现接口，**代码为准**。

## 0. 与现状的差别

现在士兵是老家格的 `(cell, soldier|eth)` cohort，部队只是账本。改动后：

- 编成部队（`ARMY_EMBARK`）：人、资金、家族子账、人物句柄 → 部队 lane；老家 cohort 相应减少。
- 拆编（`ARMY_DISEMBARK`）：lane → 该格 soldier cohort（资金随人）。
- 随军期间：口粮由 **部队库存** 供应；其它消费在 **部队所在格** 的市场（客籍消费）。
- 部队所在格无商人 / 非本国控制：买不到日用，满意度缓降，口粮照常。

## 1. 经济侧（E1 负责）

### 1.1 存储：`ArmyPersonnelStore`（新文件 `runtime_economy_army_personnel.h/.cpp`）

SoA，按 **army handle → dense row**（开放寻址或 handle→row 表），行字段：

```text
active:u8  country_slot:i32  cell:i32  population:i64  funds:i64
epoch_income:i64  epoch_expense:i64  satisfaction_q16:i32  survival_q16:i32
family_offset/len:i32 (稀疏 (family_handle, people, funds) 三元组，可先留空但要能存)
person_offset/len:i32 (重要人物句柄，先留空)
ration_q16:i32   // Military 每日发布的军供满足率
```

要求：稠密 id、无字典/字符串；未使用的 handle 不建行；删除行时压缩并保持 CSR 一致。

### 1.2 命令（POD 车道，与 24 号同规格）

| opcode | 名称 | payload0 | payload1 | target_cohort | target_cell | target_country |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | `COMMAND_ARMY_EMBARK` | 人数 | 0 | **army handle** | 来源格 | 源 signature（soldier\|eth） |
| 31 | `COMMAND_ARMY_DISEMBARK` | 人数 | 0 | **army handle** | 目标格 | 目标 signature（soldier\|eth） |
| 32 | `COMMAND_ARMY_MERGE_LANES` | 人数 | 0 | **src army handle** | — | —（payload1 = dst army handle） |

规则：
- EMBARK：从 `(target_cell, target_country)` cohort 取 `min(人数, 该 cohort 人口)`，**人口与资金按比例**转移进 lane（资金 = cohort 资金 × 比例，向下取整，余数留源）。lane 不存在则创建，`country_slot` 由格 owner 决定。
- DISEMBARK：从 lane 取 `min(人数, lane 人口)`，转移到 `(target_cell, target_country)` cohort（不存在则建）；资金按比例回流。lane 清空则释放行。
- MERGE_LANES：`payload1` 为 dst handle，把 src 的整条 lane 并入 dst（人口/资金/家族/人物全并），释放 src。
- 三者都必须**守恒**：总人口、总资金不变；不允许跨格搬人（EMBARK 只从 `target_cell` 取，DISEMBARK 只写 `target_cell`）。
- 全部走 `apply_command`（主运行时）并被 POD 准入白名单放行（24/30/31/32）。
- 幂等：按 `sequence` 去重（与 24 同机制）。

### 1.3 客籍消费（经济日阶段）

在居民清算之后、市场结算之内（复用现有 household 内核），对每条 active lane：

```text
若 lane.cell 的 controller == owner == lane.country_slot 且该格有活商人：
    用 soldier_household 的「非军供需求」（跳过 state_supplied_need_ids）按 lane.funds 购买
    计算 satisfaction_q16 / survival_q16 写回 lane
否则：
    这些需求记为未满足（满意度按现有内核衰减），不再尝试市场
```

军供需求（staple_food / protein）的满足率取 `lane.ration_q16`（见 1.4），不进市场。

### 1.4 军供接口

```cpp
void NativeEconomyRuntime::set_military_army_ration(uint64_t army_handle, int32_t q16);
int64_t military_army_population(uint64_t army_handle) const;   // 供桥接对账
```

### 1.5 存档

PKEC schema +1；新增 lane 段（handle、人口、资金、收入/支出、满意度、cell、ration）。旧档拒绝并给出明确 reason（沿用现有风格）。

## 2. 军事侧（E2 负责）

### 2.1 意图与转换

- `army.create` / `army.station` / `army.disband` / 歼灭与撤退：现有代码已经在搬 lot；
  需要新增 **人口意图**：
  - 编成：`MILITARY_INTENT_ARMY_EMBARK {army, cell, count, signature}`
  - 拆编：`MILITARY_INTENT_ARMY_DISEMBARK {army, cell, count, signature}`
  - 补员合并：`MILITARY_INTENT_ARMY_MERGE_LANES {src army, dst army}`
- 桥接把它们翻成 opcode 30/31/32（POD 车道，签名由经济侧解析）。
- 对账：`military_army_population(handle)` 与部队 lot 人数对齐；差值为阵亡/自然死亡时从 lot 扣减（复用 `reconcile_soldier_roster` 的思路，改成按部队）。

### 2.2 按位置供粮

- `publish_military_ration_satisfaction` 增加**部队分支**：对每支 active 部队调用
  `set_military_army_ration(handle, army.ration_ratio_q16)`；驻防分支保持现状（按格发布）。
- 部队消耗本来就按部队库存计算（`run_consumption` 的 army holder），无需改动。
- 部队在无商人/敌境时：口粮仍由库存供给，只有日用消费失败（经济侧处理）。

### 2.3 测试

- `military_runtime_smoke_test.gd`：编队后断言「老家 soldier cohort 减少、部队人口 = 编入人数」；
  行军到敌境后断言「部队人口不变、口粮库存下降」；拆编后断言「人口回到目标格」。
- 新增 `tests/military/army_personnel_probe.gd`（报告用）：每 5 天打印部队人口、lane 资金、
  满意度、所在格、口粮余量。
- 120 天活世界探针不得回归（名册与经济逐点一致）。

## 3. 边界与不做

- 不做海运运兵、不做独立空军。
- 家族子账与重要人物句柄**只要求能存能并**，不做家族效果联动（后续）。
- 客籍消费只在「本国控制且有商人」的格发生；不做黑市/掠夺式消费。
- 军饷：随军人员军饷仍由国库 → lane 资金的转移（`PAY_WAGES` 改为对 lane 转账，若时间不够可先继续按老家格发放并登记为已知缺口）。
