# 基本食品生产者现金循环修复方案

## 1. 背景与目标

对应经济记录：

`economy_record_20260724_161540_v19_cell1715_q21_r28`

目标是修复商人采购、生产者出售和企业营运资金分配，使有真实市场需求、具备物理生产条件的基本食品生产者能够持续获得现金，同时保持：

- 货币与商品严格守恒；
- 商人仍由本地 merchant cohort 共同持有现金和库存；
- C++ 原生经济运行时继续作为唯一权威；
- 不新增每建筑持久现金账户或平行经济系统；
- 不通过无限收购、长期补贴或无上限库存积累维持企业。

## 2. 数据结论

基本食品生产者的主要问题不是默认商人收购价过低，而是当前采购数量会在库存达到目标后断崖式归零。

| 产业 | 售出率 | 收入 / 生存成本 | 若售出率接近 100% 的粗略覆盖率 |
|---|---:|---:|---:|
| gathering_ground | 37.8% | 34.2% | 约 90.5% |
| freshwater_fishing_camp | 21.5% | 22.4% | 约 104.2% |
| marine_fish_collector | 接近 0 | 0% | 需先排查资源与物理产能 |

同时：

- `gathered_plants` 后期库存约 43,472,997；
- `fish` 后期库存约 7,632,450；
- gathering_ground 后期利润率约 -71.6%；
- freshwater_fishing_camp 后期利润率约 -55.8%；
- 默认商人收购系数约为零售价的 95%。

因此，采集和渔业的核心矛盾是“市场持有大量旧库存，但当前产出无法持续转换为生产者现金”，不是简单的食品物理短缺或收购折价过大。

狩猎属于独立物理问题：旧记录中 `wild_game` 从约 24,435 降至约 4。必须先用自然资源安全采集修复后的新数据确认可持续产量，不能用采购或价格机制掩盖资源耗竭。

## 3. 当前机制的关键缺陷

主要代码位于 `gdext/src/economy_runtime.cpp`。

### 3.1 库存目标导致采购悬崖

当前库存型商品的采购配额近似为：

```text
quota = min(sellable, max(0, inventory_target - current_stock))
```

当库存达到目标后，采购配额立即为零。生存品优先级只参与商人现金分配，不能突破零配额。因此，即使家庭仍持续消费食品，生产者也会在旧库存高于目标时失去现金收入。

### 3.2 同商品报价按稳定 group 顺序执行

运行时先聚合每种商品的总配额和预算，再逐个执行该商品的生产者报价。较早的 group 可能耗尽共同配额或现金，使后续 group 长期零成交。这会造成同类生产者之间的顺序性饥饿。

### 3.3 关键企业仅获得 25% 初始营运资金

同一 `(cell, owner_signature)` 下的企业共用 cohort 现金。当前关键候选先获得约 25% 的期望投入成本，然后再按评分分配余额。对存在硬投入、组合投入或最小生产批次的食品企业，25% 可能不足以完成一次有效生产。

### 3.4 提高收购价不能修复零配额

默认买价系数约为 95%。当 `quota = 0` 时，提高买价仍然产生零收入，并会在配额恢复后更快消耗商人预算。因此价格与配方只能在采购数量和现金分配修复后校准。

## 4. 修复方案

### 阶段 A：将库存补缺改为预测消耗后的补货

保留现有库存目标，但使用下一个采购窗口结束时的预测库存计算补货量：

```text
forecast_withdrawal =
    household_withdrawal_ema
  + business_withdrawal_ema
  + export_withdrawal_ema

projected_stock = max(
    0,
    current_stock - forecast_withdrawal * procurement_horizon_days
)

restock_quota = max(0, inventory_target - projected_stock)
```

对于生存品，加入有上限的连续补货量：

```text
high_water_mark = inventory_target * 1.20

continuity_quota = min(
    sellable,
    forecast_withdrawal * procurement_horizon_days,
    max(0, high_water_mark - projected_stock)
)

procurement_quota = min(
    sellable,
    max(restock_quota, continuity_quota)
)
```

要求：

- `procurement_horizon_days` 取现有结算周期或从现有 market-making 配置派生，不能任意写死；
- 不得重复计算已经包含在库存目标中的需求；
- 高水位倍率先以 1.20 作为 A/B 起点，最终由数据调整；
- 当库存高于高水位时，不执行连续补货下限。

### 阶段 B：处理已有超额库存

新算法不能无条件收购现有过剩产出。若 `current_stock > high_water_mark`：

- 暂停连续补货，仅保留真实库存缺口或紧急短缺采购；
- 生产规划按真实预计销量下调产能；
- 允许家庭消费、生产投入、贸易和正常价格机制消化库存；
- 库存回到高水位以内后自动恢复连续补货。

机制要保障的是“需求所需的食品生产能力持续获得现金”，而不是让所有现有食品建筑无条件满负荷运转。

### 阶段 C：按经济用途分配现有商人采购预算

不新增账户，只对当前周期的临时采购预算分阶段使用：

```text
merchant_available_budget =
    merchant_opening_cash * (1 - cash_reserve)

分配顺序：
1. 生存品连续补货与库存缺口；
2. 关键生产投入品的库存缺口；
3. 普通消费品库存缺口；
4. 奢侈品和非必要库存。
```

第一阶段按实际可执行采购需求分配，不使用固定食品预算百分比。完成基本需求后，再将余额交给现有的确定性加权 water-fill 逻辑。

需要新增诊断字段或等价聚合：

```text
merchant_opening_cash
merchant_procurement_budget
survival_restock_required_value
survival_restock_allocated_value
merchant_procurement_spent
household_sales_inflow
business_input_sales_inflow
trade_sales_inflow
merchant_closing_cash
```

重点指标：

```text
merchant_reinvestment_ratio =
    procurement_spent /
    (household_sales_inflow + business_input_sales_inflow + trade_sales_inflow)
```

该指标用于区分“商人没有经营性流入”和“商人有钱但采购优先级分配错误”。

### 阶段 D：同商品生产者按比例结算

对每种商品先计算总可成交量：

```text
Q = min(
    total_sellable,
    good_quota,
    floor(good_budget / buy_price)
)
```

再按每个报价者的可售数量确定性分配：

```text
q_i_raw = Q * sellable_i / total_sellable
q_i = deterministic_round(q_i_raw)
```

舍入余数按稳定 group 顺序逐单位或前缀比例分配，保证：

- 总成交量严格等于 `Q`；
- 总付款与库存变化严格守恒；
- 相同输入和存档得到相同结果；
- 不再由 group 顺序决定谁长期零销售。

结算仍使用现有现金流：

```text
merchant_cash -= q_i * buy_price
producer_owner_cash += q_i * buy_price
market_stock += q_i
```

### 阶段 E：保证食品企业一个最小可执行生产批次

继续复用 `_building_working_capital_allocated`，不增加持久企业账户。

对每个 owner signature 的现金按以下顺序分配：

1. 保留完整基础工资现金缺口；
2. 为物理可生产且预计可销售的生存食品建筑，支付一个需求对齐的最小可执行批次；
3. 为关键生产投入建筑支付最小可执行批次；
4. 用现有短缺、下游压力和利润缺口评分分配剩余现金；
5. 普通与低优先级企业最后获得资金。

食品建筑的最小批次规模应受以下约束：

```text
minimum_executable_output = min(
    sustainable_harvest_capacity,
    available_input_capacity,
    merchant_expected_purchase_quota,
    configured_survival_output_floor
)
```

这里的资源约束不是取消食品优先级，也不是行政禁止向猎场投资。市场短缺和高价格仍应提高狩猎生产的优先级，但资金不能创造不存在的猎物。可资助规模必须受当期可持续捕获量约束：

| 资源状态 | 营运资金处理 |
|---|---|
| 资源充足，且再生量能够覆盖开采量 | 按需求、利润信号和正常产能配置 |
| 资源偏低，但仍存在可持续产量 | 保留食品优先级，只资助可持续产量对应的生产批次 |
| 当期资源为零或不可采 | 本周期不配置生产投入；保留建筑，资源恢复后自动重新参与资金竞争 |

因此，资金上限应近似为：

```text
fundable_output = min(
    merchant_expected_purchase_quota,
    available_input_capacity,
    physical_resource_capacity,
    sustainable_harvest_capacity
)

working_capital_required =
    input_cost_for(fundable_output)
  + protected_wage_gap
```

`sustainable_harvest_capacity` 应来自自然资源安全采集机制，而不是仅按资源当前存量或建筑理论满产计算。资源恢复后，该上限随可持续产量上升，猎场自然获得更多可执行资金。这样既响应价格和短缺信号，也避免“资源越少、价格越高、捕获激励越强、资源耗竭越快”的公地悲剧反馈。

不得：

- 仅因食品短缺就按理论满产规模向资源不足的狩猎生产配置资金；
- 为没有预计采购配额的过剩食品生产借款；
- 对 owner livelihood 做第二次现金预留；
- 绕过现有工资、债务和守恒结算顺序。

### 阶段 F：最后校准价格、配方与产出

完成 A-E 后，按基本食品建筑测量：

```text
cash_conversion =
    merchant_paid_revenue / sellable_retail_value

operating_coverage =
    merchant_paid_revenue /
    (input_cost + base_wages + owner_livelihood_cost)
```

只有当成交量健康而 `operating_coverage < 1` 时，才按以下顺序调整：

1. 自然资源与物理产能；
2. 配方投入和产出率；
3. 默认价格与成本锚；
4. 单商品商人收购系数；
5. 目标利润率和工资参考值。

不得用提高价格掩盖零配额、资源耗竭或资金分配错误。

## 5. 建议代码落点

主要修改文件：`gdext/src/economy_runtime.cpp`。

- `merchant_inventory_target(...)`：保留库存目标职责；如需要，可新增只计算采购窗口预测库存/配额的局部 helper；
- 采购配额生成段：将 `target - stock` 改为预测库存后的补货与受限连续补货；
- 每商品预算分配段：先满足生存补货与关键投入，再执行现有加权 capped redistribution；
- offer 执行段：由逐报价者消耗共享 quota 改为每商品确定性比例分配；
- working-capital candidate 段：用最小可执行批次替代关键候选统一 25% 初始拨款；
- `economy_csv_recorder.cpp`：补充商人现金循环和生存补货诊断字段；
- 对应原生测试：增加库存高水位、同商品公平结算、营运资金优先级和守恒测试。

如新增 helper，应保持局部、无持久状态，并沿用现有整数定点、饱和运算和确定性舍入工具。

## 6. 实施顺序

建议按以下顺序分别提交和验证：

1. 验证自然资源安全采集后的新基线；
2. 实现预测补货、高水位和超额库存状态；
3. 实现商人生存品/关键投入预算优先级；
4. 实现同商品生产者比例结算；
5. 实现食品最小可执行营运资金；
6. 增加 recorder 诊断；
7. 根据新数据校准价格、配方和产出。

避免一次性混合机制修复与数值调参，否则无法判断改善来自哪个因果环节。

## 7. A/B 验证矩阵

使用相同种子、相同初始存档，每阶段至少运行一个完整游戏年度：

| 版本 | 变更 |
|---|---|
| A0 | 当前基线 |
| A1 | 仅自然资源安全采集 |
| A2 | A1 + 预测补货与库存高水位 |
| A3 | A2 + 商人采购预算优先级 |
| A4 | A3 + 同商品比例结算 |
| A5 | A4 + 最小可执行营运资金 |
| A6 | A5 + 经数据证明必要的配方/价格调参 |

验收指标：

- 生存食品 `stock / target` 大部分时间位于约 `0.85-1.20`；
- 库存不长期单调累积；
- 需求对齐的 gathering 和 fishing 售出率显著高于当前 37.8% 和 21.5%；
- 活跃基本食品生产者 `operating_coverage` 接近或超过 1.0；
- 同商品生产者成交份额与可售份额相符，不因 group index 长期为零；
- 生存补货有缺口时，普通商品不得先耗尽商人预算；
- 商人保留现金仍满足流动性要求；
- `population_error`、`money_error`、`goods_error` 继续严格为 0；
- 食品短缺、饥饿死亡、建筑清算和资源耗竭同步改善。

若生产者现金改善但食品库存持续上涨、商人现金枯竭、死亡率上升或守恒失败，则修复不合格。

## 8. 本方案明确不做的事项

- 不新增市场独立现金账户；
- 不新增每建筑持久营运资金账户；
- 不无限收购所有食品产出；
- 不长期依靠显式铸币补贴基本食品生产者；
- 不单独提高商人买价作为首要修复；
- 不把食品优先级解释为无视物理资源约束；资金按可持续产量配置，资源恢复后自动恢复资助资格；
- 不在验证机制修复前同时大规模调整价格和配方。
