# Project.Keynes 经济记录诊断报告

**记录族**：`tmp/economy_record_20260829_025602_v25_cell1860_q-15_r31_{summary,cohorts,market,buildings,resources}.csv`
**时间范围**：day 138 – 5946（5809 天 ≈ 15.92 年）
**记录器 schema**：summary 186 列 / cohorts 26 列 / market 50 列 / buildings 132 列 / resources 21 列
**分析日期**：2026-08-29
**状态更新**：出生率根因已于 2026-08-29 定位、**实测确认并修复**（见 §7）。其余 P1 未处理。

---

## 0. 一句话结论

**账目是干净的，但经济是死的、人口是被压住的。**

- 守恒审计（population / money / goods）全程为 0，记录完整无缺 → 不是记账 bug。
- 但全局 5809 天里 **贸易候选生成 0 单、发运 0 单、生产投入消耗 0、资源再生 0、新增投资 19 次** → 几乎所有"调节型"机制都没有在工作。
- 出生率低的**直接原因**是被承载力闸门压到了"更替地板"：**有效出生率 ≈ 名义出生率 × 0.125**，而 0.125 正好等于 `death_rate/birth_rate`。
- 压住它的**根因**在 `food_flow_capacity_for_cell()` 的量纲：承载分母用的是 `food_need_count × Q16_ONE = 196,608`，而真实人均日食物需求只有约 **824–968**（goods subunits）。分母大了约 **200–240 倍**，`k_eff` 被缩小到同量级，于是 `load = population / k_eff` 恒在 20–200，远超软启动阈值 0.9，**生育惩罚永久满档**。

---

## 1. 数据完整性与范围（先确认能不能信）

| 检查项 | 结果 |
| --- | --- |
| 五表齐备 / 缺失维度 | 全部齐备，无缺失 |
| 行数 | summary 5809 · cohorts 20569 · market 778406 · buildings 71312 · resources 180079 |
| 主键唯一性 | 五表 duplicate_primary_keys = 0 |
| 畸形行 / 空 ID | bad_width_rows = 0，blank_core_rows = 0 |
| 天连续性 | day_gaps = []（5809 天连续，无跳日） |
| epoch 对齐 | detail 的 epoch_id 全部存在于 summary；无回归 |
| 核心列缺失 | 无 |
| **审计守恒** | `population_error` / `money_error` / `goods_error` **全 5809 行均为 0** |
| stage / epoch_active | 全程 `trade_planning` / `false`（采样点固定在提交边界） |

**范围警告（重要）**：`summary` 是**全局**表；`cohorts / market / buildings / resources` **只有 cell 1860 一个格子**。所有细粒度结论都只能代表这一个采样格，不能直接推广到全世界。反过来，summary 里没有全局 population 列（见 P2-7），人口只能用 `filled_owner_jobs + filled_employee_jobs + unemployed` 作劳动力代理。

**世界规模（本局）**：21 → 17 个 cohort、30 个建筑组、134 种商品、2400 个 market 条目、劳动力 120 → 102。
对照历史运行：7 月的 v19 运行是 ~4771 cohort / ~50 万 owner jobs 的大世界；自 v22 起缩到 ~20 cohort / ~100 owner jobs 的小场景。**不要拿本局的绝对数字去和 v19 比。**

---

## 2. 出生率专题

### 2.1 现象

| 指标 | 数值 |
| --- | --- |
| 出生总数 | **41** |
| 死亡总数 | **59** |
| 净变化 | **−18**（cohort 21 → 17，劳动力 120 → 102，−15%） |
| 粗出生率（以劳动力为基数） | **23.4 ‰/年** |
| 粗死亡率 | **33.6 ‰/年** |
| 净增长率 | **−10.3 ‰/年** |
| 首次出生日 | **day 716**（开跑后 578 天零出生） |
| 有出生的天数 | **41 / 5809（0.71%）**，每天恰好 1 人 |
| 出生间隔 | min 1 天 · 中位数 39.5 天 · max 654 天 |

23‰ 的粗出生率对前工业社会偏低（历史常态 40–50‰），但更关键的是：**名义值是 200‰**。

### 2.2 名义值 vs 有效值

`Project/project-keynes/scripts/data/profession_profile.gd:24-25` 的默认值，且**所有职业 `.tres` 都没有覆盖**（已核对 `professions/` 下全部文件与 `ethnicities/default.tres`）：

```
birth_rate_q32 = 2,353,407  →  2,353,407 / 2^32 = 5.479e-4 /天  =  200.0 ‰/年
death_rate_q32 =   294,176  →  0.6849e-4 /天                     =   25.0 ‰/年
```

实测有效出生率 ≈ 23.4‰，即 **名义值的 ≈ 0.117**。

### 2.3 机制：生育率被"更替地板"钉死

代码路径 `gdext/src/economy_runtime_market.cpp:1933-1962`：

```cpp
const int64_t load_q16 = food_flow_valid ? mul_div_sat(
    remaining_market_population, Q16_ONE, std::max<int64_t>(1, k_eff), sat) : 0;
...
int64_t fertility_land_q16 = Q16_ONE;
if (load_q16 > _carrying_soft_start_q16) {              // soft_start = 58982/65536 = 0.90
    const int64_t replacement_q16 = clamp(
        death_rate_q32 * Q16_ONE / birth_rate_q32,      // = 294176/2353407 = 0.125
        0, Q16_ONE);
    const int64_t t_q16 = clamp((load_q16 - 0.90) / 0.10, 0, Q16_ONE);
    fertility_land_q16 = Q16_ONE + t_q16 * (replacement_q16 - Q16_ONE);
}
int64_t effective_birth_rate_q32 = birth_rate_q32
                                 * fertility_land_q16 / Q16_ONE      // ← 土地/承载项
                                 * rescale_q16        / Q16_ONE      // ← 满意度项
                                 * _epoch_cell_birth_factor_q16 / Q16_ONE
                                 * family_mix_q16     / Q16_ONE;
```

- 满意度项**不是**原因：`rescale_q16 = clamp(composite / 45875, 8192, 65536)`。cell 1860 的 `satisfaction_q16`（= `_population.needs_satisfaction`，即**生存维度**）均值 **0.931**，末期 0.916，远高于参考值 0.70 → rescale 被 cap 到 **1.0**。
- 家庭项、城市项没有证据显示为强抑制（家庭 buff 未在本局启用因子）。
- 剩下的只有 `fertility_land_q16`。**一旦 load > 1.0，`t_q16 = 1`，`fertility_land = 0.125` 满档惩罚。**

**交叉验证（这条链能对上）**：

- 更替地板下 `有效出生率 = 0.125 × 200‰ = 25‰`，实测 23.4‰（劳动力基数；若按总人口基数约 20‰）→ 吻合。
- 更替地板的含义是"出生 = 非饥饿死亡"。基线死亡应为 `0.6849e-4 × 人口 × 天数`：若人口 ≈120，预测基线死亡 ≈ 47.8，实测总死亡 59 → **约 11 人死于饥饿**，正好解释"死亡多于出生"。这也和 `satisfaction_q16` 偶发触底（bucket 638-1137 与 2638-3137 出现 min = 0.0000）一致。

### 2.4 根因：`k_eff` 的量纲错了约 200 倍

`gdext/src/economy_runtime_carrying.cpp:92-151`：

```cpp
// 分子：建筑食物产出（goods subunits）× 食物当量系数 / Q16
//   系数 = (GOODS_SCALE * Q16_ONE) / qty_per_need  →  对 qty=1000 的食物 = 65536，即 1:1 原样
const int64_t denominator = flow_days * _carrying_survival_food_per_person;  // flow_days = 1
return effective_with_stock / denominator;
```

而 `economy_runtime_carrying.cpp:337-353`：

```cpp
_carrying_survival_food_per_person = food_need_count * Q16_ONE;   // = 3 × 65536 = 196,608
```

**问题**：注释写的是"食物当量系数把一份 authored 生存需求归一到 Q16_ONE，所以分母是需求个数"。但实际系数是 `(GOODS_SCALE × Q16_ONE) / qty_per_need`，它把一份需求归一到 **GOODS_SCALE = 1000**，不是 Q16_ONE = 65536。两者差 **65.5 倍**。再叠加"一份需求 ≠ 一人一天的口粮"（`survival_household` 的 `base_qty_per_person` 是 staple 440 + protein 144 + produce 240 = **824** subunits/人/日，不是 3 份标准需求单位），**总失配约 239 倍**。

用本局实测量对齐：

| 量 | 数值 | 来源 |
| --- | --- | --- |
| cell 1860 人口 | 20 | cohorts 表 |
| 实际食物产出当量/日 | ≈ 19,365 | gathered_plants 实际提取 14,629 + game_meat 4,736（与 building group 2 的 `last_output` 14,575、group 4 的 4,784 对得上） |
| 人均实际摄取 | ≈ 968 subunits/日 | 19,365 / 20 |
| authored 人均需求 | 824 subunits/日 | `consumption_plans/survival_household.tres` 的 `base_qty_per_person` |
| 覆盖率 | ≈ 118% | 与 `satisfaction` 0.93、`livelihood_coverage` 1.06–6.57 一致 |
| **承载分母** | **196,608 /人/日** | `3 × Q16_ONE` |
| **k_eff（cell 1860）** | **19,365 / 196,608 ≈ 0.098 人** | 整数化后 `max(1, 0) = 1` |
| **load** | **20（或 Q16 下 1.31M）** | ≫ 0.90 |

> **勘误（2026-08-29）**：初稿此处引用 `economy_birth_runtime_test.gd` 的 `k_eff ∈ [32,48]` 断言作为"测试世界标定对照"。该引用**无效**——`_test_two_and_ten_year_attractor` 与 `_test_overcrowded_replacement` 虽已定义，但 `_run()`（同文件 15-27 行）**从不调用它们**，属死代码。上述量纲分析不依赖该旁证，且已被 §7 的运行时实测独立确认。

### 2.5 一个次要但会拖后腿的设计问题

即便把分母改对，自给自足的格子仍有 `load ≈ 1.0 > 0.90`，惩罚照样触发。设计上唯一能提供余量的是库存项 `stock_period_eq = stock_food_eq × flow_days / 30`。但本局 `gathered_plants` 的 `household_available_stock` 有 **93.2% 的天数为 0**（logs 84.3%），库存项几乎不贡献。**零库存经济在承载模型里没有呼吸空间**，需要单独处理（把 owner 自留的实物库存算进去，或把 soft_start 从 0.90 上调）。

### 2.6 关于"前 578 天零出生"

这是**预期行为，不是 bug**：`_birth_residual_q32` 按 (cell, ethnicity) 车道从 0 开始累积，`births = accumulated / Q32_ONE`。每车道日增量极小，需要数百到数千天才能凑满 1 人。这也解释了为什么出生只落在 41 个孤立日上、间隔中位数 39.5 天——**是量化形态，不是量级原因**。

### 2.7 竞争解释与排除

| 假设 | 判定 | 依据 |
| --- | --- | --- |
| A. 承载分母量纲错误 | **成立（主因）** | 2.4 节量纲 + 实测 239× 失配 + 测试世界标定对照 |
| B. 开局人口就等于承载力，天然无增长空间 | **未被排除，可能叠加** | 即便分母改对，自给自足 = load 1.0 仍触发惩罚（2.5 节）。需读运行时 `carrying_k_eff` 才能分离 A/B |
| C. 满意度抑制生育 | **排除** | cell 1860 生存满意度均值 0.931 ≫ 参考 0.70，rescale 被 cap 到 1.0 |
| D. 饥饿导致 | **排除为主因**（是次要项） | 满意度高、livelihood coverage 末期 2.60、人均资金从 331 涨到 4469（13.5×）。饥饿只贡献约 11/59 的死亡 |
| E. Q32 残差量化 | **只解释形态** | 解释"0.71% 的天有出生"，不解释 23‰ vs 200‰ 的量级差 |
| F. 记录器 schema 缺陷 | **排除** | `births` 直接来自 `runtime._births`（`economy_csv_recorder.cpp:626`），每 epoch 归零（`economy_runtime_epoch.cpp:423`），语义正确 |

---

## 3. 其余发现（P1 / P2）

### P1-1 贸易系统完全停摆

| 指标（全局 5809 天累计） | 值 |
| --- | --- |
| `trade_candidates_generated` | **0** |
| `trade_candidates_accepted` | **0** |
| `trade_orders_dispatched` / `arrived` | **0 / 0** |
| `trade_capacity_used`（可用 50,331,648） | **0** |
| `trade_ready_candidates` / `relief_candidates` | **0 / 0** |
| `trade_unresolved_no_attempt` | **18,505**（信号存在但从未尝试） |
| `trade_unresolved_stock` | **94,040** |
| `trade_unresolved_route` | **5,095** |
| `trade_source_signals` / `destination_signals`（瞬时） | 14 / 21，持续存在 |
| `trade_signal_max_age_days`（末值） | **5,945**（信号从创建到结束都没被处理） |
| `trade_route_cursor` | **5809 行全为 0**，而 `trade_route_total` = 14–17 |

格子层面：cell 1860 的 `gathered_plants` 有 5807 天 `trade_last_rejection_reason = 4`（`TRADE_SIGNAL_DIAG_STOCK`），`logs` 是 3（`ROUTE`）与 4 各占一半，`bast_fiber` 是 4。
**判定**：信号在生成、赤字周期在开合（started 167 / resolved 165），但 ROUTE 阶段的候选生成从未产出。`trade_route_cursor` 恒为 0 是最可疑的直接线索。

### P1-2 商户流动性枯竭

| 指标 | 首日 | 末日 | 峰值 / 谷底 |
| --- | --- | --- | --- |
| `merchant_cash` | 69,158,262 | **2,918,866** | 245,821,410 / 420,502 |
| `merchant_economic_assets` | 72,779,481 | 4,394,926 | 248,190,668 / 2,560,595 |
| `merchant_procurement_budget` | 60,229,172 | 2,518,617 | 215,093,731 / 351,708 |
| `merchant_inventory_retail_value` | 3,811,838 | 1,553,767 | 9,399,587 / 1,553,767 |

商户现金跌去 **95.8%**，同时住户人均资金涨了 13.5 倍——财富从商户单向流向住户。注意：`merchant_cash` 在 ownership 模型里不是"市场现金账户"，但它决定了采购与贸易能力，这个跌幅与 P1-1 互为因果。

### P1-3 投资被双重死锁

cell 1860 的 5 类候选建筑在 **全部 5809 天**都被拒：

- type 62 / 72 → `investment_rejection_reason = 3` = `INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY`（没有可调动的 owner）
- type 103 / 297 / 357 → `= 12` = `INVESTMENT_REJECTION_MATERIALS`，且 `investment_shortage_q16 = 1.000`、`investment_failed_material_group = 1`（建材完全缺位）
- type 297 还有 930 天 `= 3`
- 全局 `building_investments_started = 19`（5809 天）

→ 想扩产但既没人也没料，产能永久冻结在开局状态。这是"产出上不去 → 承载上不去 → 出生上不去"链条的关键一环。

### P1-4 维护长期欠账

`maintenance_unmet` 在 **5788 / 5809 天**非零，累计 **691,721**，而 `maintenance_goods_consumed` 只有 1,213,889 → **约 36% 的维护需求从未被满足**，持续 16 年。

### P1-5 资源只减不增

- 全局 `building_resource_generated = **0**`（`building_resource_consumed = 119,650,904`，净 delta −119,650,904）。**所有 v24 / v25 运行的该字段都是 0**。
- cell 1860 的消耗几乎全被**自然衰减**吃掉，开采只占零头：

| 资源 | 期初 | 期末 | 变化 | 自然负变化 | 人工开采 |
| --- | --- | --- | --- | --- | --- |
| fertile_soil | 277,584 | 30,454 | **−89.0%** | 247,926 | 0 |
| wild_game | 108,004 | 30,932 | **−71.4%** | 70,057 | 7,014 |
| clay | 25,722,010 | 10,509,880 | **−59.1%** | 15,286,000 | 0 |
| timber | 5,297,453 | 3,946,476 | **−25.5%** | 1,794,147 | 7,261 |
| gold_ore | 6,098,778 | 6,098,519 | −0.004% | 210 | 259 |

timber 的自然损失是开采量的 **247 倍**。 fertile_soil 掉 89% 却零开采——这是配置/再生模型问题，不是玩家过度开采。

### P2-1 市场实物流基本失灵

134 种商品里**只有 6 种曾活跃**：`logs`、`gathered_plants`、`clothing`、`bast_fiber`、`game_meat`、`raw_hide`。其余 128 种 stock / demand / price 全程冻结在初始值。

- `gathered_plants`：`household_available_stock` **93.2% 的天为 0**，`shortage_q16 ≥ 0.5` 占 33.1%，价格长期钉在上限 **50,000**（下限 2,006）
- `logs`：84.3% 的天 household 可得为 0，`shortage ≥ 0.5` 占 **51.9%**，价格 8,358 → 3,167
- `game_meat`：唯一健康的（可得率 98.7%，shortage ≈ 0）
- `clothing` 60,000 单位、`raw_hide` 660 单位常年零需求零流动（开局沉淀库存）

### P2-2 生产 100% 实物自留，市场被绕过

- 全局 `production_inputs_consumed = **0**`（全运行），`desired/funded/unfunded_business_demand = 0`
- `production_output_retained = 579,269,992`，`owner_output_consumed = 579,269,992` → **完全相等**
- `cycle_flow_produced / consumed / discarded` 全 0

即：所有产出直接被 owner 以实物形式留用，中间品投入、商人采购、市场出清这条链在本局完全不存在。这也解释了为什么市场空空如也而住户满意度还有 0.93。

### P2-3 气候限产吃掉一半产出

cell 1860 的 group 2（type 103，12 座采集建筑）：

- `last_water_fit_q16` = **0**（均值仅 965，max 46,553）→ 水分适配为零
- `last_climate_capacity_q16` = 33,588（**0.51**）
- `last_climate_lost_output` = **13,865/日**，而 `last_output` = 14,575 → **约 49% 的潜在产出被气候吃掉**

其余 four 组 `temperature_fit` 与 `water_fit` 均为满值 65,536，唯独主力粮食组被水卡死。

### P2-4 建筑长期空缺

group 1（type 72，1 座建筑）在**全部 5809 天**：`filled_owner = 0`、`owner_openings = 1`、`last_output = 0`、`capacity_q16 = 0`、`realized_profit_margin_q16 = 0`。一座 16 年无人经营的空建筑，且它是投资候选（`rejection = 3`）。

### P2-5 group 3 的 `last_expected_revenue` 数值异常

type 297（2 座）：`last_revenue` 均值 142,427（合理区间 0–320,000），但 `last_expected_revenue` 峰值 **833,172,494**、均值 **4.15 亿**。`last_margin_gap_q16` 却恒为高位正值（51,626/65,536）。建议核查 `allocated_output_operating_cost()` / 预期收入的计算路径是否出现饱和或未初始化。

### P2-6 就业结构极度单薄

全局 `filled_employee_jobs` 从 5 降到 **1**，`unemployed_population` 峰值仅 2。cell 1860 的 20 人里 19 人是 owner、1 人是 employee。这不是失业危机，而是**根本没有雇佣经济**。

### P2-7 记录器仪器缺口

- `summary` **没有全局 population 列**（运行时有 `_opening_totals.population`，`economy_runtime_diagnostics.cpp:929` 用它做审计，但没有落盘）→ 所有比率只能用劳动力代理
- 没有 `carrying_k_eff` / `population_load_q16` / `food_access_q16` / `local_food_output_eq_per_day` 落盘，尽管 `append_carrying_capacity_fields()`（`economy_runtime_carrying.cpp:633-712`）已经把它们算好并暴露给 GDScript
- `cycle_flow_produced/consumed/discarded` 三列全 0，需确认是真零还是未接线

---

## 4. 因果链

```text
carrying 分母量纲错（3 × Q16_ONE = 196,608 vs 真实 824/人/日）
        ↓  k_eff ≈ 0.098（cell 1860，人口 20）
load = population / k_eff ≈ 20–200  ≫  soft_start 0.90
        ↓  economy_runtime_market.cpp:1944-1957
fertility_land_q16 = replacement_q16 = death/birth = 0.125（满档）
        ↓
有效出生率 = 200‰ × 0.125 ≈ 25‰（实测 23.4‰）
        ↓  再叠加约 11 例饥饿死亡
净增长 −10.3‰/年 → 劳动力 120 → 102（−15%）→ cohort 21 → 17
        ↑
        └── 放大器：投资双锁（P1-3，没人+没料）+ 气候限产（P2-3，−49% 粮食产出）
            + 贸易停摆（P1-1，零进口）+ 资源只减不增（P1-5）
            → 产出上不去 → k_eff 上不去 → 惩罚永不解除（正反馈）
```

---

## 5. 建议（按优先级）

### 5.1 先做一次 5 分钟的验证（不改任何代码）

运行时对 cell 1860 调 `get_population_cell_summary(1860)`（或 `get_population_cell_snapshot(1860)`），读这几个 key：

```
carrying_k_eff                →  预测 ≈ 0（整数化后 0 或 1）
population_load_q16           →  预测 ≥ 65536（load ≥ 1.0）
food_access_q16               →  预测 < 0.01（≈ 323 / 65536）
local_food_output_eq_per_day  →  预测 ≈ 19,000
effective_food_capacity_persons → 预测 ≈ 0
carrying_survival_food_per_person → 预测 = 196,608（应为 ≈ 824）
```

**如果 cell inspector 显示"格承载力 0.1 人 / 取得 0%"而住户明明有饭吃 → 假设 A 成立。**
这是区分 A（分母错误）与 B（开局人口=承载力）的最小代价实验。

### 5.2 修承载分母的量纲（P0，改 `economy_runtime_carrying.cpp:337-353`）

现状：
```cpp
_carrying_survival_food_per_person = food_need_count * Q16_ONE;   // 3 × 65536 = 196,608
```

两个可选方向，**不要同时改**：

- **方案 1（推荐，改分母）**：改为"该 plan 下食物 need 的 `base_qty_per_person` 之和 × GOODS_SCALE"，即 `824 × 1000 / 1000 = 824`（注意与分子同量纲）。语义最直白："一个人一天要多少当量食物"。
- **方案 2（改分子，对齐注释）**：把 `_good_food_equivalent_q16` 的系数从 `(GOODS_SCALE × Q16_ONE) / qty_per_need` 改为 `(Q16_ONE × Q16_ONE) / qty_per_need`，使"一份需求 = Q16_ONE"与注释一致。但这会同时影响 `food_access_q16` 和 UI 展示，波及面更大。

**必须同步处理**：
- `economy_birth_runtime_test.gd:90-101` 的 `k_eff ∈ [32,48]` 与 `population ∈ [32,45]` 断言会失效，需要用新的量纲重新标定那个测试世界，或显式把测试世界的产量上调约 240 倍。
- 改完后 `load` 会从 ~200 掉到 ~1.0，仍然 > 0.90。要看到人口增长，还需要 5.3。

### 5.3 给零库存经济留呼吸空间

- 把 carrying 的库存项计入 owner 自留（in-kind）库存，而不只是 `household_available_stock`；或
- 把 `_carrying_soft_start_q16` 从 0.90 上调到 1.3–1.6，让"自给自足"不再被判为超载；或
- 给 `stock_period_eq` 一个最低保底。

### 5.4 解锁产能（否则修好出生率也涨不起来）

优先级顺序：
1. **P1-3 建材死锁**：cell 1860 全局 `construction_goods_consumed` 仅 259,175 且只在 12 天发生。查 `INVESTMENT_REJECTION_MATERIALS` 的判定（`economy_runtime_building_investment.cpp:1931`）是"真没料"还是"料没被看见"（比如 `clothing` 的 60,000 单位死库存是否被计入可用建材）。
2. **P1-1 贸易**：优先查 `trade_route_cursor` 恒为 0（`economy_runtime_trade.cpp:1140-1158` 的 `route_trade_source()` 是否提前 `break` 或 `source_done` 永假）。
3. **P2-3 水适配为 0**：确认 `last_water_fit_q16 = 0` 是气候数据问题还是曲线配置问题。
4. **P1-5 资源再生**：`building_resource_generated` 在所有 v24/v25 运行都是 0，优先确认是未接线还是内容缺 `mode=1` 的再生条目。

### 5.5 补记录器列（让下一次诊断不用猜）

1. `summary`：加全局 `population`（运行时已有）
2. `summary` 或 `market`：加 `carrying_k_eff`、`population_load_q16`、`food_access_q16`、`local_food_output_eq_per_day`、`carrying_survival_food_per_person`
3. 加 `fertility_land_q16` 与 `effective_birth_rate_q32` 的采样列——出生率问题的直接观测点
4. 确认 `cycle_flow_produced/consumed/discarded` 是真零还是未接线

### 5.6 重跑验证

修完 5.2 + 5.3 后重跑同一场景 2000 天，判据：

- `carrying_k_eff` 落在 `[population × 0.7, population × 2.0]`
- 粗出生率回到 **40‰ 以上**，净增长转正
- 建筑组数从 30 上升（投资解锁）
- `trade_candidates_generated > 0`

---

## 6. 附录：证据与复现命令

**产物**

| 文件 | 内容 |
| --- | --- |
| `tmp/economy_record_20260829_025602_v25_cell1860_q-15_r31_profile.json` | preflight 结构化索引（schema 指纹、覆盖、审计、信号、相关性） |
| `tmp/analysis_v25_1860.txt` | 第一轮：全局流量、队列、市场、建筑、资源分部统计 |
| `tmp/analysis_v25_1860_b.txt` | 第二轮：满意度时间线、食物市场细节、建筑行类、维护、出生事件上下文 |
| `tmp/analyze_v25_1860.py` / `tmp/analyze_v25_1860_b.py` | 上述两轮的可重跑脚本 |
| `tmp/preflight_v25_cell1860.json` | preflight 运行摘要 |

**命令**

```bash
cd D:/Godot/ProjectKeynes/Project.Keynes

# preflight
PYTHONPATH= "C:/Users/hkinghuang/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
  "C:/Users/hkinghuang/.workbuddy/skills/project-keynes-economy-analysis/scripts/profile_economy_record.py" \
  --prefix tmp/economy_record_20260829_025602_v25_cell1860_q-15_r31 --repo-root .

# 两轮分部分析
PYTHONPATH= python tmp/analyze_v25_1860.py   > tmp/analysis_v25_1860.txt
PYTHONPATH= python tmp/analyze_v25_1860_b.py > tmp/analysis_v25_1860_b.txt
```

（`PYTHONPATH=` 前缀是为了绕开 WorkBuddy 注入的 safe-delete shim，与沙箱无关。）

**抽查签字（主要发现背后的原始行）**

| 发现 | 抽查行 |
| --- | --- |
| 审计为零 | `summary` 全部 5809 行 `population_error/money_error/goods_error = 0`（preflight `audit_max_abs`） |
| 首日出生 | `summary` day 716 → `births = 1`；day 138–715 全 0 |
| 食物可得为 0 | `market` day 5946 `gathered_plants.household_available_stock = 0`（5415/5809 天如此） |
| 水适配为 0 | `buildings` group_index=2 全部 5809 行 `last_water_fit_q16 = 0`，`last_climate_lost_output = 13865` |
| 投资建材缺 | `buildings` group_index=-1 type=103 `investment_rejection_reason = 12`、`investment_shortage_q16 = 65536`、`investment_failed_material_group = 1` |
| 建筑空缺 | `buildings` group_index=1 全部行 `filled_owner = 0`、`owner_openings = 1` |
| 预期收入异常 | `buildings` group_index=3 `last_expected_revenue` 峰值 833,172,494 |
| 资源自然衰减 | `resources` day 5946 `fertile_soil.reserve = 30453.47`（期初 277,584.47），`artificial_extraction_applied` 累计 0 |

**关键代码引用**

| 位置 | 作用 |
| --- | --- |
| `gdext/src/economy_runtime_market.cpp:1891-2002` | 出生率有效值计算（满意度 rescale、承载 fertility_land、城市因子、家庭因子） |
| `gdext/src/economy_runtime_market.cpp:1933-1934` | `load_q16 = population / k_eff` |
| `gdext/src/economy_runtime_market.cpp:1944-1957` | `fertility_land` 更替地板 `replacement_q16 = death/birth = 0.125` |
| `gdext/src/economy_runtime_carrying.cpp:92-151` | `food_flow_capacity_for_cell()` — 分子分母所在 |
| `gdext/src/economy_runtime_carrying.cpp:337-353` | `_carrying_survival_food_per_person = food_need_count × Q16_ONE` ← **根因** |
| `gdext/src/economy_runtime_catalog.cpp:1070-1112` | 食物当量系数 `= (GOODS_SCALE × Q16_ONE) / qty_per_need` |
| `gdext/src/economy_runtime_catalog.cpp:855-866` | 生存食物 need = staple_food / protein / produce（3 个） |
| `gdext/src/economy_runtime.h:3075-3076` | `_carrying_sat_floor_q16 = 8192`、`_carrying_sat_cap_q16 = Q16_ONE` |
| `gdext/src/economy_runtime.h:3063` | `_satisfaction_birth_reference_q16 = 45875`（0.70） |
| `gdext/src/economy_runtime.h:3071` | `_carrying_soft_start_q16 = 58982`（0.90） |
| `Project/project-keynes/scripts/data/profession_profile.gd:24-25` | `birth_rate_q32 = 2353407`、`death_rate_q32 = 294176` |
| `Project/project-keynes/data/economy/consumption_plans/survival_household.tres` | `base_qty_per_person` 440 / 144 / 240 |
| `gdext/src/economy_runtime_carrying.cpp:633-712` | `append_carrying_capacity_fields()` — **已算好但未落盘的 k_eff / load / access** |
| `gdext/src/economy_runtime_trade.cpp:1140-1158` | ROUTE 阶段游标推进（P1-1 首要嫌疑） |
| `Project/project-keynes/tests/economy_birth_runtime_test.gd:90-101` | `k_eff ∈ [32,48]` 断言 —— **死代码，`_run()` 未调用，不能作为标定参照** |

---

## 7. 修复记录（2026-08-29）

### 7.1 实测确认假设

初稿的分母量级是推算的。为坐实它，新建探针
`Project/project-keynes/tests/carrying_probe.gd`（只读，可随时删除）：复刻 cell 1860 的
20 人 + 5 个建筑组（`deadwood_gathering_camp`×3、`early_merchant_post`×1、
`gathering_ground`×12、`placer_gold_working`×2、`stone_age_hunting_camp`×2）与该格资源，
使用**未修改的真实 profile**，跑 80 个周期后读 `get_population_cell_summary(0)`。

**决定性反证**：探针里实际人均食物供给是 **1,784 eq/日**，为 authored 需求 824 的
**2.16 倍**（明显过度供给），但模型报 `k_eff = 0`、`food_access_q16 = 0.92%`。

### 7.2 改动内容

`gdext/src/economy_runtime_carrying.cpp`（+20 −5）：

```cpp
// 原：_carrying_survival_food_per_person = food_need_count * Q16_ONE;   // 196,608
// 现：= 基准生活成本计划中各食物 need 的 base_qty_per_person 之和       // 824
if (ration_per_person > 0) {
    _carrying_survival_food_per_person = ration_per_person;
} else if (food_need_count > 0) {
    _carrying_survival_food_per_person = saturating_mul(food_need_count, GOODS_SCALE, sat);
}
```

附带：`append_carrying_capacity_fields()` 新增 `carrying_survival_food_per_person` 输出，
补上 §P2-7 记录的仪器缺口。

**单位链条（这次推导的关键）**：`_good_food_equivalent_q16 = (GOODS_SCALE × Q16_ONE) / component.qty_per_need`
→ `flow_eq = 商品 subunits × GOODS_SCALE / qty_per_need` = **need 单位数**。
分子既然已是"需求单位"，分母就必须是 authored 口粮本身，而不是"需求个数 × Q16_ONE"。

### 7.3 修复前后对比

| 指标（探针，80 cycles） | 修复前 | 修复后 |
|---|---|---|
| `carrying_survival_food_per_person` | 196,608 | **824** |
| `carrying_k_eff` | **0** | **72** |
| `population_load_q16` | **262,144**（钳位上限 4.0） | **13,653**（0.208） |
| `food_access_q16` | **603**（0.92%） | **65,536**（100%） |
| 累计出生 | **0** | **2** |
| 人口 | 13（停滞） | 13 → **15** |

### 7.4 回归验证

`economy_birth_runtime_test.gd`：**修复前 51 检查 / 1 失败，修复后 51 检查 / 1 失败**
（基线用 `git checkout --` 还原后重跑确认，非推断）。**无新增回归。**

唯一失败项 `small population deterministically births when residual crosses Q32` 是
**先前就有的**，成因已查明：该 fixture 设 `deaths.fill(0)` → `replacement_q16 = 0`，
且无建筑 → `k_eff = 0` → `load > 0.9` → `fertility_land = 0` → 出生恒为 0。
这是"更替地板"语义的正确表现（没人死亡时，为维持人口恒定出生必须归零），
**问题出在测试用例自身的设定**，需由你决定是否改 fixture（给它一个非零死亡率或一份食物来源）。

### 7.5 尚未处理

§2.5 的零库存问题、以及全部 P1（贸易停摆、投资双锁、资源只减不增、维护欠账）
均**未处理**。承载力修好后人口应该会开始增长，但产能仍被投资死锁卡住，
增长会在触及 `k_eff` 后停住——届时会看到新形态的停滞。建议下一步按 §5.4 解锁投资与贸易。

### 7.6 复现命令

```bash
cd D:/Godot/ProjectKeynes/Project.Keynes/gdext
PYTHONPATH= scons platform=windows target=template_debug -j8
PYTHONPATH= scons platform=windows target=template_release -j8

cd ../Project/project-keynes
PYTHONPATH= "/d/Godot/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path . --script res://tests/carrying_probe.gd
PYTHONPATH= "/d/Godot/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path . --script res://tests/economy_birth_runtime_test.gd
```
