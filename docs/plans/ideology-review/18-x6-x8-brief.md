# 18 - X6 理念元机制 / X8 上下游（reviewer brief，2026-10-23 22:25）

补齐 Doc 02 最后两项规格。X6 全部在 Ideology POD 内；X8 复用 X1-b 核，必须排在 X1-b 之后。只走 worker。不调数值。

## 1. X6 现状

已有（不用重做）：
- 理解度速度、重抽费、时代衰减下限、抽卡张数 4 个国家 stat，冻结进 POD
  （`runtime_ideology_pod.h:188-194`，`understanding_gain_q16` 等 `:253-263`）。offer 容量 5。
- 理念点增益 `country.ideology.point_gain_factor`（已被 15 张卡使用）。
- 封存 `BAN_CARD=11`、保底分区、refine。

缺：
- 槽位顺序：`RuntimeIdeologyPodIdeaState`（`:285`）只有 location，没有 slot index；`active_idea_ids` 按 id 排序。
- 免费抽：opcode 表（`:50-62`）没有 FREE_DRAW，OPEN_OFFER 必扣点（`runtime_ideology_pod.cpp:1258`）。
- 分项理念点倍率（「人口增长一项 ×1.4」）：`PointLedger` 有 population/building/trade 三项（`:367-374`），但只有一个总倍率。
- 「每装备 1 张 X 流派」计数 → 17 §5 的理念侧标量，不在本文重复。

## 2. X6 方案

### X6-a 分项理念点倍率（最小，先做）
- 新增 3 个国家 stat：`country.ideology.point_population_factor` / `point_building_factor` / `point_trade_factor`
  （MULTIPLY，钳 0.5..3.0），与现有 4 个同样在 epoch 冻结进 POD，`accrue_points` 分别乘到三项上，再乘总倍率。
- 主线程与 worker 必须走同一个共享核（沿用 `ideology_trade_flow_q16` 的做法）。IDP2 ABI +1（新冻结列）。
- 验收：只开人口项 ×2 → 一期理念点 = 人口项×2 + 其余不变（逐项读 ledger）。

### X6-b 免费抽
- 行状态加 `uint16_t free_draws`（PKID + IDP2 存档）。`OPEN_OFFER` 时 `free_draws>0` 则不扣点、`free_draws--`。
  **不新增 opcode**：玩家仍发 OPEN_OFFER，是否免费由状态决定，UI 读 `free_draws` 显示。
- 发放：由 X4 事件或卡效果给（`ERA_CHANGED` → `era_renewal` L3；层数满 → `civil_examination` L3）。发放走新的
  Effect 动作 `IDEOLOGY_GRANT_FREE_DRAW`（Effect→Ideology 的自定义域命令，与现有 GRANT_POINTS 同形）。
- 保底：**免费抽推进保底计数**（与收费抽完全同流程，RNG 消耗次数不变）。写进测试。
- 版本：PKID +1、IDP2 ABI +1（可与 X6-a/X6-c 合并为一次）。

### X6-c 槽位顺序与复制相邻槽
- `IdeaState` 加 `uint8_t slot_index`（用 `reserved[0]`，字节布局不变；但语义变化仍 bump 版本）。
  EQUIP 时分配该 location 最小空槽；UNEQUIP 释放。确定性：与命令顺序相关，与容器遍历顺序无关。
- 复制（`algorithmic_governance`）：在 `collect_effect_activations` 里，复制卡把「左邻槽卡当前级的 program 列表」
  当作自己的 program，以自己的 (ideology, level) 作实例身份、magnitude × 复制倍率。**不复制 Effect 实例**。
  activation signature 混入左邻槽卡的 (id, level, generation)，邻卡变 → 复制卡重算。
  规则类（legend）卡排除由生成器给定义打 `copyable=0`。
- UI 要显示槽位顺序：本期只要求 report 字典带 `slot_index`，UI 排序留给后续。
- 验收：装 A、B、复制卡 → 复制卡复制 B；卸 B 装 C（落在 B 的槽）→ 复制 C；存读档后槽位不变。

### 明确排除
- `mass_media` L2「四张中至少一张属于已装备体系」：可用现有 route tilt 近似，由 C 改写为 v1。若必须是硬保证，列为排除。
- `reform_movement` L3「卸下保留 50% 理解度」：需要每卡历史理解度存档，本期排除。

## 3. X8 上下游

- 先决条件：X1-b 的 `source_count[tag, R]` 核已合并并有 worker 测试。
- 方案：不新增核。上游 = 生成器把「产业链上游品」展开成一个合成 tag（`cell.produces.<g1>` OR …，已有 DNF 表达力），
  卡用 X1-b 选择器 `kind 16` 以该合成 tag 为源、R=1/2。生成器从 goods/建筑配方读链（只读 .tres）。
- 邻格不同产出品种数：新 metric `cell.neighbor_distinct_goods`，提交尾对邻格 metric 45 去重计数（6 邻，小数组去重，
  不需要位图）。派生，不动 schema。
- 验收：矿→冶炼→工坊一条链，工坊格拿到上游加成，移走矿后消失（依赖 14 的 retire）。

## 4. 顺序

X6-a（可插到任意位置，很小）→ X6-b（依赖 15 的事件发放）→ X6-c → X8（X1-b 之后）。
