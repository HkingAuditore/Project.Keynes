# 军饷跟随随军人口（契约 v1）

> 2026-11-03。前提：随军 lane、客籍消费、海运均已落地（`dots_ext_army_v11`，smoke 0 失败）。
> 本契约只解决一件事：**军饷发给人在的地方**。

## 0. 现状与问题

`MilitaryCore::run_wages_and_upkeep` 现在只对**驻防格**发 `PAY_WAGES`（按格人头 × 人均日薪），桥接翻成
`COMMAND_TRANSFER_TO_COHORT`（国库 → 该格士兵 cohort 现金）。

随军后人在部队 lane 里，于是：
- lane 只有编队时带过来的那份资金，越花越少（客籍消费会把它花光）；
- 老家 cohort 已经没人了却还在收钱。

## 1. 经济侧：opcode 34 `ARMY_LANE_PAY`

| opcode | 名称 | payload0 | payload1 | target_cohort | target_cell | target_country |
| --- | --- | --- | --- | --- | --- | --- |
| 34 | `ARMY_LANE_PAY` | 金额（MONEY_SCALE） | 国家句柄 | army handle | — | — |

实现要点：

1. 走 `military_collect_cash(country_handle, amount)`（现有、已审计的"国库 → 非税支出"路径），
   拿到实际到账 `moved`；再 `lane.funds += moved`、`lane.epoch_income += moved`。
   **不要**另开铸币路径：国库减多少、lane 就加多少。
2. lane 不存在或 `moved <= 0` → 返回失败（`error` 写明原因），`settled_out = moved`。
3. POD 准入白名单加到 34；与 24/30–33 共用 `sequence` 幂等。
4. 不需要结构命令（不碰 cohort）。

## 2. 军事侧

1. `run_wages_and_upkeep` 对**部队持有人**（`location_kind == MILITARY_LOT_ARMY`）单独发
   `MILITARY_INTENT_ARMY_PAY`：`army = 部队句柄`、`count = 人头`、`amount = 人头 × 人均日薪`、
   `country_a = 国家句柄`。驻防部分保持现状。
2. 两边的"人均日薪"用同一个值（`AUTO` = 生存成本 × wage stat；`ABSOLUTE` = 政策值）。
3. 付款上限仍然受国库现金约束：`amount` 按当前可用现金截断，并计入 `pay_ratio_30` 统计
   （随军与驻防各自计入同一比例）。
4. 部队被歼/拆编时 lane 资金随人回到格 cohort（现有逻辑），不额外结算。

## 3. 桥接

1. 新增意图 → opcode 34，走 24 号那条 POD 车道（`payload0=金额`、`payload1=国家句柄`、
   `target_cohort=army handle`）。
2. 回执：POD 行的 `count` 字段暂存**付款前 lane 资金**；结算时读 `military_army_funds(handle)`，
   `applied = max(0, now - prev)`，再 `min(applied, amount)`。lane 消失 → 按 0 结算。
3. 若经济侧没有 34 的支持（旧 DLL），意图降级为 no-op + 失败回执，不得崩。

## 4. 验收

1. `military_runtime_smoke_test.gd`：编队后推进若干天，断言
   - 部队 lane 资金上升；
   - 国库支出增量 ≈ 随军人头 × 日薪 × 天数（±10%，受现金约束）；
   - 老家 cohort 的军饷不再包含随军那部分地区（拆编后回到原状）。
2. 120 天活世界：无 worker fault，名册与经济士兵一致，经济审计（人口/货币/物资）不报错。
3. 内核自测：驻防/随军两种持有人各发一笔，金额守恒。

## 5. 不做

- 不做军饷拖欠、欠薪利息、逃兵（已有士气/组织度路径）。
- 不改驻防路径的量级。
