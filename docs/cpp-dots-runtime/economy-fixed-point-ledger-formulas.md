# Market V2 / Price V3 定点数、需求曲线与守恒账本

## 数值 ABI

人口为整数 `i64`；资金尺度 10,000；物资尺度 1,000；价格是每完整物资单位的
10,000 资金尺度；比例/满足度为 Q16；率/余数 ABI 为 Q32。尺度写入 schema V2 存档，
改变尺度必须显式迁移。权威状态不保存浮点数。

`mul_div_sat(a,b,d)` 在 MSVC 使用 `_umul128/_udiv128`，Clang/GCC 使用
`unsigned __int128`。符号与 magnitude 分离处理，朝零截断；除零或越界饱和并增加
`saturation_count`，不得依赖有符号溢出。

财富/价格弹性使用版本固定的整数 `pow_q16` 近似；环境曲线使用 17 个 Q16 样本线性
插值。不得在权威公式中调用平台 `pow()` 或运行时 GDScript Callable。

## 资金与商品账本

资金账户只有 cohort funds 和 treasury。市场库存属于该地块全部商人 cohort，市场本身
没有现金账户。购买执行：

```text
buyer funds -= actual cost
merchant cohort funds += population-weighted share(actual cost)
market stock -= actual component quantity
```

同一交易内扣款和收入严格相等。显式命令支持 treasury transfer、mint、burn、库存
增减、人口增减、迁移和换签名；V2 游戏行为只依赖显式库存增加，不生成商品或工资。

BUILDING_GRAPH 在居民清算前执行 role-level 自适应工资转账：

```text
living_floor = max(local_base_living_cost, local_profession_living_cost)
contract_wage = bounded_move(previous, max(living_floor, local_contract_wage_ema))
base_due = filled_employee_jobs * contract_wage * epoch_days
base_paid = proportional_post_sale_owner_cash_share(base_due)
owner funds/expense -=/+ base_paid
employee funds/income += stable_prefix_share(base_paid)
```

生产只按业主现有资金购买物理投入，不预付工资；产出出售后，同一 owner 对全部 role 比例支付。
最终欠薪只形成诊断和取消奖金，不追溯停止本期生产。随后，
`25% * max(0, revenue - input - base_due - target_owner_profit)` 成为员工奖金池。
基础工资与奖金都是 cohort 间转账，既不改变总资金，也不进入 explicit mint/burn。

企业采购和实际生产使用两个容量：

```text
purchase_intent_capacity = min(available, owner employment, each critical role employment,
                               owner input-cash coverage, natural-resource coverage)
realized_capacity        = min(purchase_intent_capacity, each local input-stock coverage)
business_demand          = unit input * building_days * purchase_intent_capacity
realized_profit_margin   = (sales - input cost - base wages due)
                           / max(input cost + base wages due, MONEY_SCALE)
```

本地缺货不把采购意图归零，只把实际产能压到库存瓶颈；无人、无输入资金、资源枯竭或
`SUSPENDED_LOSS` 则两者均为零。实际有经营成本的利润率连续三周期 `<= -25%` 后停产；无生产且
无成本的纯缺货周期不累计。停产期用当前价格、最低有效输入成本和合同工资计算反事实利润，连续
两周期 `>= +10%` 且业主资金覆盖一栋一周期成本后恢复。

商人采购预算为：

```text
target = (realized_withdrawal_ema + export_ema) * target_inventory_days
       + max(feasible_household_and_business_demand - realized_withdrawal_ema, 0) * epoch_days
cold_start_target = max(target, offered_daily_output * 1 day)  # 无消费/出口历史
gap = max(target - current_stock, 0)
procurement_budget = opening_merchant_cash * 75%
good_budget_share = procurement_budget * (gap * buy_price) / sum(gap * buy_price)
```

预算余数按稳定 good ID 和 building group 顺序落位；金银铸币结算不受普通采购预算限制。

每次提交严格校验：

```text
closing_population = opening_population + explicit_population_delta
closing_money      = opening_money + explicit_mint - explicit_burn
closing_stock      = opening_stock + explicit_stock_delta - consumed_goods
```

任何误差非零或内部不变量破坏都进入 fatal；不为千万 cohort 创建回滚副本。

不存在按建筑数量无条件发行的商站铸币行为。货币内生发行只能来自市场实际接受的
金银产出，发行数量受建筑到岗、投入、真实矿藏、产出和接受量共同约束。

类别生产投入使用 good-level 效率换算物理消耗：

```text
effective_unit_cost = price * Q16 / efficiency_q16
physical_required   = ceil(effective_required * Q16 / efficiency_q16)
```

候选先受冻结科技与最低质量门控，再按有效单位成本、good stable index 排序选择。goods 守恒扣除
`physical_required`，不会把低等级工具先转换为通用工具。

## 编译后的需求 ABI

V2 hot loop 不使用旧的逐 rule formula registry。资源在 bootstrap 编译为：

```text
plan_need_offsets
need(priority, base_qty, wealth elasticity/min/max, quantity_env_curve)
need_variant_offsets
variant(preference, price elasticity, preference_env_curve)
variant_component_offsets
component(good_id, qty_per_need)
```

平均按 16 needs 设计，plan 硬上限 32；每 need 最多 8 variants，每 variant 最多 4
components。`fixed_per_capita` 等旧 FormulaDefinition 仅保留 ABI/数学回归兼容，不在
Market V2 household hot loop 调用。新增 V2 行为应扩展版本化 native kernel 和 catalog
schema，而不是注册 GDScript 公式。

## 数量、替代和互补

需求量由人口、人均财富幂函数、民族 need factor、sample-day 环境曲线和周期天数相乘。variant 权重由
基础偏好、价格弹性和偏好环境曲线决定，再以稳定整数份额拆分 need。一个 variant 的
多个 components 是互补 bundle，实际 bundle 数取各 component 可供量的最小值；同一
need 的 variants 是替代品，首选不足只允许一次 fallback，防止组合搜索爆炸。

资金和库存短缺使用累计前缀商：

```text
allocation_i = floor(prefix_i * available / total)
             - floor(prefix_(i-1) * available / total)
```

顺序固定为 market、cohort slot、need priority、variant、component。该方法精确耗尽可用
额度且无逐单位余数循环。

## 生存、劳动与死亡

目录仍保留主食、蛋白质和蔬果三个内部子 need，以表达营养、价格和技术替代；生存判定把它们
按实际 desired/filled 数量合并为一个食品篮子。衣着单独计算，数量先乘 17 点温度曲线；最热端
允许曲线为零，因此无需衣着也视为满足。权威 Q16 值为：

```text
food_sat     = sum(food_filled) / sum(food_desired)
clothing_sat = clothing_desired == 0 ? 1 : clothing_filled / clothing_desired
survival_sat = min(food_sat, clothing_sat)
starvation_deficit = max(0, starvation_satisfaction_threshold - survival_sat)
```

周期开始时仍存活人口先就业和生产，不用上周期满足度削减劳动力。默认饥饿满足度阈值是 50%；
低于阈值的缺口乘 `starvation_death_rate_q32`，与 cohort 的既有 Q32
死亡率及 `demography_residual` 合并后按周期天数确定性取整。死亡计入 `births/deaths` 和人口
守恒；每个仍有市场库存的地块至少保留一名人口，避免产生无所有者库存。

## 价格

每个商品以 `period_demand/N` 更新居民需求 EMA；effective alpha 为
`min(1, daily_alpha*N)`。Price V3 的总需求是居民需求 EMA 与稀疏企业投入需求 EMA 之和；
供给使用建筑实际 offer（含未成交丢弃、排除业主留用）EMA。每个活跃 `(cell, good)` 只维护一条稀疏信号，
不存在 `market×good×building` 稠密矩阵。

```text
excess = (total_demand - offered_supply) / max(GOODS_SCALE, total_demand + offered_supply)
inventory = (target_inventory - stock) / max(GOODS_SCALE, target_inventory)
cost = confidence * (cost_anchor - price) / max(cost_anchor, price)
pressure = w_excess*excess + w_inventory*inventory + w_shortage*shortage
         + w_cost*cost + w_idle*inactive_reversion
elastic_pressure = pressure / demand_price_elasticity
```

成本锚来自实际原料成本、应付合同工资与 `target_operating_margin_q16` 目标利润，按显式 output
cost share 或参考产值份额分摊；`adaptive` 合同工资已由基础生活篮子、岗位生活篮子和当地工资
EMA 形成硬下限，因此生活成本通过工资进入成本锚，不再另加一个会重复计算的价格项。金银法定
发行品不使用零售成本锚。供给不足时成本锚置信度随供给降低，避免没有成交的理论成本强推价格。
无需求、无供给、无库存的商品缓慢回归目录默认价。

价格变化先应用 good-specific `price_adjust_q16` 与单日 max rise/fall，再以
`daily_change*N` 做确定性一阶冻结积分，最后应用绝对 min/max。该算法避免对每个
market-good 做 N 次反馈或幂运算；误差由版本化 `production_income_consumption_v4`
近似契约显式控制。

cohort income EMA 同样读取周期净收入日均值，effective alpha 为
`min(1, N/8)`。`epoch_income/expense` 保存周期总额。

## 新内容 SOP

- 新 good：新增 `GoodProfile`，配置默认价、上下限、EMA、目标库存、压力权重与日涨跌幅。
- 新职业：新增 `ProfessionProfile` 并指定默认 consumption plan。
- 新民族：新增 `EthnicityProfile` 与稀疏 need modifiers。
- 新 need/bundle：编辑 `NeedProfile`/`ConsumptionPlanProfile`，保证稳定 ID 与上限。
- 新环境影响：新增 17 点 `EnvironmentDemandCurveProfile`，选择四种已捕获 signal。
- 新 native 数学：增加 schema/version、golden、scalar/batch 等价和 microbench，并重编 DLL。

`GoodProfile` 还必须校准需求价格弹性、超额需求/成本锚/闲置回归权重以及企业需求、供给、
成本 EMA alpha。`BuildingProfile` 必须配置目标营业利润率与供给价格弹性；多产出配方只有在
默认参考产值分摊不合适时才填写 `output_cost_shares_q16`，其总和必须严格等于 Q16_ONE。

## 贵金属发行与周期流账本

金银 producer offer 使用目录固定面值，而不是本地价格或 merchant funds：

```text
issued = floor(accepted_goods * monetary_issue_value / GOODS_SCALE)
owner_funds += issued
explicit_money_mint += issued
market_stock += accepted_goods
```

只有 stable ID `gold`、`silver` 可配置正发行值。`bullion_money_issued` 等于金银分项发行额之和；
早期 merchant 矿点因此把发行额直接交给矿点业主，后期 industrialist 矿山同样遵循此公式。
金银后续交易是普通 cohort 间转账，不再次 mint。周期流物资在 utility prepass 进入 MarketStore，同周期工业输入照常计入
`production_inputs_consumed`；周期末剩余量计入 `cycle_flow_discarded`，因此 goods 守恒为：

```text
closing_stock = opening_stock + explicit_stock_delta + accepted_output
                - household_consumption - construction_inputs
                - production_inputs - cycle_flow_discarded
```

业主留用是同一周期内的生产 source 与 owner consumption sink：实际消费量同时计入
`production_output_retained` 和 `owner_output_consumed`，两项在 goods audit 中对消；未消费留用品
直接进入 `production_output_discarded`，不进入 closing stock。它不产生收入、支出或商人结算。
