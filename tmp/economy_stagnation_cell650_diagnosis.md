# cell 650 经济与人口停滞诊断

**记录器**：`tmp/economy_record_20260831_140522_v25_cell650_q45_r10_{summary,buildings,cohorts,market,resources}.csv`
**范围**：553 个 epoch，第 49054–49606 天，无缺日。`summary` 为全局；四张明细表仅为采样格 **cell 650 (q45, r10, s-55)**。
**守恒校验**：`population_error` / `money_error` / `goods_error` 全程 553 天全为 0 → 账务闭合，本问题**不是记账缺陷**，而是机制/配置/标定问题。

---

## 0. 一句话结论

cell 650 被锁在一个 **「劳动力 ← 粮食 ← 投资」三角死锁**里：四条食物链建筑因为**零业主**而 `capacity_q16 = 0`，而"零业主 → 零收入"又使劳动力再分配闸门永远打不开；人口因 `staple_food` 100% 未满足而不增长；新增产能又因"现有同类建筑已有空缺"(`OWNER_VACANCY`) 被 100% 拒绝。外部贸易无法破局——全世界都没有这些商品的盈余。

---

## 1. 症状

| 指标 | 起始 | 结束 | 备注 |
|---|---|---|---|
| 格内人口 | 34 | 32 | 553 天净 -2，峰值 35 |
| 人口加权满意度 | 1.000 | **0.781** | **第 49066 天**跌破基线 0.05——与鱼库存首次归零同一天 |
| 人口加权生计覆盖率 | 1.319 | **0.836** | 队列 3 低至 0.168、队列 13 低至 0.476 |
| `worst_need_id` | 16 | 16 | 全员 553 天恒定。密集 ID 16 = **`staple_food`** |
| 已填业主岗位 | 33 | 31 | 业主空缺 84 → 86 |
| 建筑组数 / 建筑栋数 | 13 / 88 | 13 / 88 | **553 天零变化** |
| 全局出生 / 死亡 | 16 / 15 | | 净 +1 人 |
| 全局 `filled_employee_jobs` | 0 | 0 | 全程无任何雇佣 |

---

## 2. 主因 A：食物链建筑全部零产能

`shortage_q16` 的定义是 **成交量缺口**，不是库存缺口：

```cpp
// gdext/src/economy_runtime_market.cpp:2156-2159
const int64_t shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
    Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE, good_demand[good], sat), 0, Q16_ONE);
_market.last_shortage_q16[idx] = static_cast<uint16_t>(std::min<int64_t>(Q16_ONE - 1, shortage));
```

`rice_grain` / `prepared_staples` / `game_meat`：库存 0、`offered_supply_ema` 0、`realized_withdrawal_ema` 0、`shortage_q16 = 65535`（100%）持续 553/553 天。

四类建筑本应供粮，但全部 `capacity_q16 = 0`、`last_output = 0`：

| type_id | 建筑 | 产出 | 业主占用 | 阻塞原因 |
|---|---|---|---|---|
| **387** | `wild_rice_marsh` | rice_grain | **0 / 4** | **`paddy_land` 本格恒为 0**；且 `water_fit_q16 = 14043`(21%) |
| **103** | `gathering_ground` | gathered_plants | **0 / 7** | 仅缺业主（`fertile_soil` 有 30,142） |
| **45** | `communal_hearth` | prepared_staples | **0 / 1** | 缺业主 + 投入品 `gathered_plants`/`game_meat` 库存为 0 |
| **152** | `marine_fish_collector` | fish | **2 / 6** | 唯一在跑的食物源，产能仅 33% |

### 2.1 稻泽是结构性死亡的（配置错配）

`Project/project-keynes/data/economy/buildings/wild_rice_marsh.tres`：

```
production_climate_profile_id = &"paddy_crop"
resource_ids = PackedStringArray("paddy_land")
resource_quantities_per_day = PackedInt64Array(120)
resource_interaction_modes = PackedStringArray("capacity")
resource_access_modes = PackedStringArray("local")
behavior_id = "consume_local_resources"
```

而 cell 650 的资源表：

| 资源 | 起始 | 结束 | 安全产量/天 |
|---|---|---|---|
| **`paddy_land`** | **0.0** | **0.0** | 0 |
| `arable_land` | 125,000 | 125,000 | 0（**全程未用**）|
| `plantation_land` | 140,000 | 140,000 | 0（**全程未用**）|
| `pasture` | 160,000 | 160,000 | 0（**全程未用**）|
| `fertile_soil` | 30,133 | 30,142 | 0 |
| `marine_fish` | 316,121 | 316,285（**反而上升**）| 46,730（实际仅采 ~1/天）|
| `timber` | 4,562,104 | 4,559,502 | 6,246,566（实际仅采 ~1.5/天）|
| `wild_game` | 1,865.5 | 1,864.6 | 906（预测寿命 129 天）|

**即使把稻泽塞满人，它也产不出一粒米。** 同时 `stone` 1.47 亿、`iron_ore` 3,481 万、`copper_ore` 3,259 万、`flint` 3,091 万、`lead_ore` 1,461 万、`gold_ore` 309 万全部零动用——**资源不是约束，配置错配才是**。

---

## 3. 主因 B：劳动力错配且无法流动

格内职业构成：forager 13、hunter 16→15、fisher 3→2、artisan 1、merchant 1（失业）、unemployed 1。

**全部 13 名 forager 都在非食物营地里：**

| type_id | 建筑 | 业主 | 产出 | 售出 | 丢弃 |
|---|---|---|---|---|---|
| 12 | `bast_fiber_camp` | **9** / 10 | 19,604 | 21 | **19,583（99.9%）** |
| 62 | `deadwood_gathering_camp` | **4** / 44 | 11,138 | 7,492 | 0 |
| 387 | `wild_rice_marsh` | **0** / 4 | 0 | 0 | 0 |
| 103 | `gathering_ground` | **0** / 7 | 0 | 0 | 0 |

树皮纤维库存 352,801 单位，需求仅 12 单位。

### 3.1 为什么搬不过去：两道闸门都关着

- `building_owner_job_reallocations` = **553 天共 1 次**；`building_owner_mobility` = **0 次**。

**闸门一（既有业主再分配）** `economy_runtime_building_employment.cpp:2090-2092`：

```cpp
const int64_t improvement = improvement_q16(source_income, target_income);
if (improvement < transition_hurdle_q16(source_signature.profession_id,
                                        target_owner_profession)) continue;
```

而 `capacity_q16` 随业主填充率缩放（实测吻合）：

| type | 业主填充 | `capacity_q16` | 比值 |
|---|---|---|---|
| 62 | 4/44 | 5,957 | 9.1% ✓ |
| 152 | 2/6 | 21,845 | 33.3% ✓ |
| 12 | 9/10（气候限 51%）| 33,588 | 51% ✓ |
| 146 | 1/1 | 65,536 | 100% ✓ |
| 387 / 103 / 45 / 30 | 0 | **0** | 0% |

**零业主 → 零产能 → 零 `projected_owner_income` → `improvement` 为负 → 闸门永不开启。一座建筑必须先有业主，才能吸引到业主。**

**闸门二（业主流动）** `economy_runtime_building_investment.cpp:3120` 的 `++_building_owner_mobility` 只在**投资赞助人路径**内、`profession_transition` 为真时才会走到。而 `building_investments_started` 全程为 0，所以这条路径物理上不可达。

---

## 4. 主因 C：投资 100% 被拒，且拒绝原因按类型永久固定

553 天共 **14,931 条候选行**（27 条/天），**零条被接受**，395 个目录类型里只有 **27 个**被评估过。

| 拒绝码 | 含义 | 次数 | 涉及 type |
|---|---|---|---|
| **3** `ACTIVE_OWNER_VACANCY` | 同类已有建筑存在业主空缺 | 4849 (32%) | 12, 30, 45, 62, 71, 72, 320, 387, 103(50%) |
| **12** `MATERIALS` | 建材不足 | 4434 (30%) | 67, 92, 93, 94, 132, 146, 306, 377 |
| **13** `RESOURCE` | 资源/条件不满足 | 1659 (11%) | 357, 362, 381 |
| **14** `PROBABILITY` | 概率抽签跳过 | 1450 (10%) | 13, 113, 103(50%) |
| **5** `OWNER_LIVELIHOOD` | 生计线 | 1126 | 76, 325 |
| **2** `SUSPENDED_CAP` | 产能挂起 | 563 | 297 |
| **10** `PAYBACK` | 回收期 | 287 | 152 |
| **8** `INPUT_CHAIN` | 投入链 | 10 | 358 |

**每个类型每天的拒绝原因完全相同**（按 6 个时间窗核对，逐类型 100% 一致）——这是结构性锁，不是随机波动。

### 4.1 死锁核心

```cpp
// gdext/src/economy_runtime_building_investment.cpp:1585-1589
const bool vacancy = existing != nullptr &&
    existing->filled_owner < existing->owner_required;
if (vacancy && !survival_vacancy) {
    reject(INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY);
    continue;
}
```

**格内不能新建稻泽/炉灶/采集场，恰恰因为现有的这些建筑有业主空缺；而空缺又填不上。** 这正是 387/103/45 三条食物链全部走 `OWNER_VACANCY` 的原因。

**逃生口 `survival_vacancy` 也失效**（:1552-1582）：

```cpp
survival_vacancy = vacancy_quote.survival_priority &&
    vacancy_quote.executable_capacity_q16 > 0;
```

实测（第 49600 天真实组）：type 387 `survival_shortage_q16 = 65535`（粮食缺口 100%）但 `survival_priority = 0`、`opportunity_executable_capacity_q16 = 0` → 逃生口永不触发。type 357 `survival_priority = 1` 但 `executable_capacity_q16 = 6`（≈0），且被 `RESOURCE` 拒掉。

### 4.2 `investment_score_q16 = 0` 是"从未进入成功路径"的可靠指纹

`score_q16` 的唯一写入点在 `:2613`，位于"已找到赞助人"之后；而所有拒绝分支都是 `reject(...); continue;`（`:1537-1542` 的 lambda 只写 `rejection_reason`）。故 14,931 行全部 `score_q16 = 0`、`payback_days = 0`，与 `building_investments_started = 0` 完全自洽。而 `investment_utilization_q16`(19046)、`shortage_q16`(32385)、`required_capital`(2.64e7)、`return_on_capital_q16`(8.03e7) 在更早处写入，所以被拒候选也带值——**这不能解读为"评分后仍被拒"**。

---

## 5. 主因 D：贸易无法破局——全世界都没有盈余

cell 650：`trade_inbound = 0`、`trade_outbound = 0`、`trade_import_ema = 0`、`trade_export_ema = 0`，全程 553 天；`trade_first_dispatch_delay_days = -1`（从未派单）。

`trade_last_rejection_reason = 4` 持续 553/553 天（charcoal / fish / game_meat / gathered_plants / lumber / rice_grain / turf_block / reed_bundle / prepared_staples）。

```cpp
// gdext/src/economy_runtime.h:2559-2568
TRADE_SIGNAL_DIAG_STOCK = 4,   // 其他：NO_SPREAD=1 MARGIN=2 ROUTE=3 CAPACITY=5 CASH=6 ...
```

触发点 `economy_runtime_trade.cpp:1093-1104`：`lower_bound` 在 `_trade_plan.sources` 中按 `good` 查找，找不到即记 `STOCK`。**含义是全世界没有任何一格该商品有盈余**——不是路由、运力或现金问题。

全局侧同样萎靡：`trade_orders_dispatched` 553 天共 238 单、`trade_orders_arrived` 237 单（≈0.4/天），而 `trade_candidates_generated` ≈ 6,146/天。

### 5.1 `trade_signal_age_days` 高企是症状不是原因

```cpp
// gdext/src/economy_csv_recorder.cpp:1476-1479
row.trade_signal_age_days = first_seen >= 0 ? static_cast<int32_t>(
    std::clamp<int64_t>(runtime._sample_day - first_seen, 0, INT32_MAX)) : 0;
```

唯一清除点 `economy_runtime.cpp:9795-9813` 只在 `needs_trade` 变假时重置 `first_seen`。而 `target > stock` 对这些商品恒真 → 时钟永不复位：fish 20,804→21,344；turf_block 40,975→41,515；reed_bundle 41,431→41,971。`trade_deadline_exceeded` 恒为 1。

`refresh_trade_response_diagnostics()`（`economy_runtime_trade.cpp:1338-1376`）只做 `_trade_signal_max_age_days` 统计，**不清理、不降权**——计划器持续重试 2 万天龄、且永远无法满足的信号。

---

## 6. 放大器：价格信号失效

- **`shortage_q16` 按成交量算，不按库存算**：lumber 库存 40,109、`household_available_stock` 40,109，shortage 仍为 1.0（因为 `good_sales = 0`）；bast_fiber 库存 352,801、 household 326,555，shortage 也是 1.0。**"没货"和"没人买"在信号上不可区分。**
- **价格近乎冻结**：553 天内 `max/min` —— rice_grain 1.02、prepared_staples 1.01、lumber 1.00、bast_fiber 1.01、clothing 1.01、gathered_plants 1.00。只有 fish（8.9×）和 game_meat（2.0×）动了，且都是在库存真正归零之后。
- 原因 `economy_runtime.cpp:5250-5282`（引用 `:81-88` `price_adjustment_reference()`）：**上涨增量锚定在固定的 default/cost anchor 上做线性爬升，不对当前价复利**，注释原文 *"Positive pressure uses the stable default/cost anchor so repeated shortages do not compound exponentially."* 再叠加 `_good_max_price_rise_q16` 速率钳制与 `shape_price()` 的天花板阻尼。
- 价格早已是成本锚的数百倍：clothing **739×**、lumber **1,054×**、bast_fiber **426×**、gathered_plants **458×**；而 `prepared_staples` / `rice_grain` / `turf_block` / `reed_bundle` / `chipped_stone_tools` 的 `cost_anchor_price = 0`（本地从未生产过）。

---

## 7. 结构性旁证

- **完全没有工资经济**：`filled_employee_jobs` 全局恒 0；13 个组 `employee_required` 恒 0；`last_wages_paid` / `last_wages_due` 恒 0。**这不是 bug**——本格 13 个类型全是石器时代层级，且**全部未声明 `employee_profession_ids`**（而 395 个目录类型里 322 个声明了）。所以人口增长无法转化为雇佣，只能转化为更多自营业主。
- **一边挨饿一边浪费**：cell 650 末 90 天产出 3,778,576 → 售出 984,141（26.0%）、**丢弃 1,975,435（52.3%）**、留存 819,000（21.7%）。其中 `bast_fiber_camp` 丢弃率 99.9%、`lumber_plant` 丢弃率 100%。`stone_age_hunting_camp` 产出 4,158 → 售出 **0**、留存 3,806（实物报酬）、丢弃 352 —— 猎肉从不进市场，这也是 `communal_hearth` 的 `game_meat` 投入恒为 0 的原因之一。
- **钱不是约束**：`merchant_cash` 3.06 亿、`merchant_economic_assets` 16.7 亿、`unfunded_business_demand` 0、`merchant_credit_drawn` 0。
- **气候只部分有责**：`average_climate_capacity_q16` 31,355（47.8%）；稻泽 `water_fit_q16` 仅 21%，但 gathering_ground 的气候容量仍有 51%，其阻塞点纯粹是缺业主。

---

## 8. 因果闭环

```
cell 650 的 paddy_land = 0（配置错配）
   └─ wild_rice_marsh 0/4 业主 ─┐
      gathering_ground 0/7 业主 ─┤→ capacity_q16 = 0 → projected_owner_income = 0
      communal_hearth  0/1 业主 ─┘        │
                                          ▼
              再分配闸门 improvement ≥ hurdle 失败（employment.cpp:2090）
                                          │
                        ┌────────────────┘
                        ▼
        rice_grain / prepared_staples / gathered_plants 库存 = 0
                        ▼
        staple_food 100% 未满足（worst_need_id = 16 全员恒定）
                        ▼
        满意度 1.00 → 0.78，覆盖率 1.32 → 0.84（第 49066 天起）
                        ▼
        出生 16 / 死亡 15 → 人口 34 → 32
                        ▼
        无剩余劳动力 → 84–86 个业主空缺长期挂起
                        ▼
        OWNER_VACANCY 拒绝所有已有类型的新建（investment.cpp:1585）
        MATERIALS / RESOURCE / PAYBACK 拒绝所有新类型
        （逃生口 survival_vacancy 因 executable_capacity = 0 而失效）
                        ▼
        building_investments_started = 0（553 天）
                        ▼
        产能冻结在 88 栋 / 119 业主位 ──────────────► 回到顶部（闭环）

   贸易无法破局：全球无盈余 → TRADE_SIGNAL_DIAG_STOCK(4) → inbound/outbound = 0
```

---

## 9. 严重度

| 级别 | 发现 | 起病 | 幅度 | 持续性 | 置信度 |
|---|---|---|---|---|---|
| **P1** | 格内陷入永久非增长均衡，福利持续下滑 | 第 49066 天 | 满意度 -0.219、人口 -2 | 全程 | 高 |
| **P1** | `OWNER_VACANCY` + 零业主→零收入 = 吸收态，无逃逸路径 | 全程 | 14,931 候选 0 接受 | 全程 | 高 |
| **P1** | 内容错配：`wild_rice_marsh` 被种在 `paddy_land = 0` 的格子 | 第 49054 天 | 4 栋建筑永久报废 | 全程 | 高 |
| **P2** | `shortage_q16` 按成交量算，混淆"无货"与"无交易"，使价格信号不可用 | 全程 | lumber/bast_fiber 有货却 100% 短缺 | 全程 | 高 |
| **P2** | `trade_signal_age_days` 无上界、无淘汰 | 全程 | 达 41,971 天 | 递增 | 高 |
| **P2** | 52% 产出被丢弃，同时主食 100% 未满足 | 全程 | 1,975,435 / 90 天 | 全程 | 高 |
| **P2** | 记录器缺口：summary 的 `building_investment_candidates` 只统计**成功组合**的规模（investment.cpp:2650），与被评估候选数无关，全局层面看不到"评估了多少候选" | 全程 | 恒为 0，而明细表有 27 条/天 | 全程 | 中 |

---

## 10. 竞争解释与鉴别方法

| 备择解释 | 反驳证据 | 鉴别方式 |
|---|---|---|
| 只是单格样本偏差 | 可能，需对照 | 换一个 `paddy_land > 0` 的格子重录；或统计 18 个世界格子中有多少条食物链是配齐业主的 |
| 人口被全局增长上限压住 | 队列满意度/覆盖率在**下降**，`worst_need_id` 锁定 staple_food，是需求失败不是上限；且拒绝码 16 `GROWTH_LIMIT` 从未出现 | 查 `building_investment_growth_limit` 配置与 `INVESTMENT_REJECTION_GROWTH_LIMIT` 触发条件 |
| 商人现金/流动性是约束 | `merchant_cash` 3.06 亿、`unfunded_business_demand` 0、`merchant_credit_drawn` 0 | — |
| 气候是主因 | 只对稻泽部分成立（water_fit 21%）；gathering_ground 气候容量 51%，阻塞点是业主 | 对照 `last_climate_capacity_q16` 与 `capacity_q16` |
| 资源枯竭 | `marine_fish` 反而上升（316,121→316,285，安全产量 46,730/天 vs 实采 ~1/天）；`timber` 456 万（安全产量 624 万/天）；`arable_land`/`pasture`/`plantation_land` 零动用；石/铁/铜/金/铅/燧石 309 万–1.47 亿全部未动 | — |

---

## 11. 建议（按"最小可证伪"排序）

1. **配置核对（最优先，成本最低）**：导出所有格子的 `paddy_land`。若地图生成器从不给该生物群系分配 `paddy_land`，那么在此播种 `wild_rice_marsh` 就是内容缺陷——这条能直接解释"稻泽为什么必然死"。
2. **给再分配闸门加埋点**：每次拒绝时记录 `source_group / target_group / source_income / target_income / improvement_q16 / hurdle_q16`。这直接检验"零业主 ⇒ 零收入 ⇒ 闸门永不开启"。
3. **逃生口隔离测试**：把零业主生存组的 `opportunity_executable_capacity_q16` 临时置为 `Q16_ONE`，看 `survival_vacancy` 是否触发、投资是否解锁。这能区分"锁在 vacancy 规则"还是"锁在 quote 函数"。
4. **靶向重跑（最干净的证伪）**：给 cell 650 预置一个业主配齐的食物生产组（或把 `paddy_land` 设为正值），确认人口/满意度是否响应。若不响应，则"粮食优先"假说被推翻，需转向人口参数。
5. **记录器补列**：为 `market` 表补 `sales` 与 `demand`（按 cell×good），使 `shortage_q16` 可分解为"无库存"与"无成交"两类。
6. **把 `ACTIVE_OWNER_VACANCY` 与可填充性挂钩**：当格内无失业人口、且目标组 `survival_priority` 为真时，应允许扩容，而非无条件拒绝。

---

## 附录：使用的命令与产物

```bash
# preflight
python .codex/skills/project-keynes-economy-analysis/scripts/profile_economy_record.py \
  --prefix tmp/economy_record_20260831_140522_v25_cell650_q45_r10 --repo-root .

# 自建分析脚本（均在 Project.Keynes/tmp/）
an_summary.py   # 全局首尾窗口对比（186 列）
an_cohorts.py   # 队列人口/资金/满意度/覆盖率
an_market.py  an_market2.py  an_market3.py   # 活跃商品、商户去重、贸易状态、时间序列
an_build.py   an_build2.py   # 建筑分组、投资候选拒绝、survival/opportunity 字段
an_time.py    # 崩溃起病日、贸易信号龄、资源存量
an_final.py   # 汇总校验与守恒复核
```

产物：`tmp/economy_record_20260831_140522_v25_cell650_q45_r10_profile.json`（preflight 索引）

**代码引用清单**：
- `gdext/src/economy_runtime_market.cpp:2156-2159`（shortage 定义）、`:1344-1369`（demand/sales 累积）、`:2133-2152`（withdrawal EMA 含实物留存）
- `gdext/src/economy_runtime.h:2559-2568`（贸易诊断枚举）、`:1365-1384`（投资拒绝枚举）
- `gdext/src/economy_runtime_trade.cpp:1093-1104`（STOCK 分支）、`:1338-1376`（信号龄仅统计）
- `gdext/src/economy_runtime.cpp:9795-9813`（信号清除）、`:5250-5282` / `:81-88`（价格锚定与线性爬升）
- `gdext/src/economy_runtime_building_investment.cpp:1552-1589`（vacancy 与逃生口）、`:2611-2617`（score 写入点）、`:2650`（候选计数器）、`:3120`（mobility 递增）
- `gdext/src/economy_runtime_building_employment.cpp:2040-2112`（再分配闸门）、`:2166/2286`（reallocation 递增）
- `gdext/src/economy_csv_recorder.cpp:1476-1493`（信号龄与 deadline 记录）、`:1085-1125`（survival/opportunity 记录）
- `Project/project-keynes/data/economy/buildings/wild_rice_marsh.tres`（paddy_land 依赖）
- `Project/project-keynes/scripts/economy/economy_catalog.gd:1966-1985`（资源按 id 排序 → 密集 ID 映射）
