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

BUILDING_GRAPH 在 Market V2 后追加 role-level 自适应工资转账：

```text
living_floor = max(local_base_living_cost, local_profession_living_cost)
contract_wage = bounded_move(previous, max(living_floor, local_contract_wage_ema))
base_due = filled_employee_jobs * contract_wage * epoch_days
base_paid = proportional_owner_cash_share(base_due)
owner funds/expense -=/+ base_paid
employee funds/income += stable_prefix_share(base_paid)
```

同一 owner 资金不足时全部 role 比例支付且 owner-lot 本期停产。生产销售完成后，
`25% * max(0, revenue - input - base_due - target_owner_profit)` 成为员工奖金池。
基础工资与奖金都是 cohort 间转账，既不改变总资金，也不进入 explicit mint/burn。

每次提交严格校验：

```text
closing_population = opening_population + explicit_population_delta
closing_money      = opening_money + explicit_mint - explicit_burn
closing_stock      = opening_stock + explicit_stock_delta - consumed_goods
```

任何误差非零或内部不变量破坏都进入 fatal；不为千万 cohort 创建回滚副本。

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

平均按 16 needs 设计，plan 硬上限 32；每 need 最多 4 variants，每 variant 最多 4
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

## 价格

每个商品以 `period_demand/N` 更新居民需求 EMA；effective alpha 为
`min(1, daily_alpha*N)`。Price V3 的总需求是居民需求 EMA 与稀疏企业投入需求 EMA 之和；
供给使用建筑实际 offer（含未成交丢弃）EMA。每个活跃 `(cell, good)` 只维护一条稀疏信号，
不存在 `market×good×building` 稠密矩阵。

```text
excess = (total_demand - offered_supply) / max(GOODS_SCALE, total_demand + offered_supply)
inventory = (target_inventory - stock) / max(GOODS_SCALE, target_inventory)
cost = confidence * (cost_anchor - price) / max(cost_anchor, price)
pressure = w_excess*excess + w_inventory*inventory + w_shortage*shortage
         + w_cost*cost + w_idle*inactive_reversion
elastic_pressure = pressure / demand_price_elasticity
```

成本锚来自冻结采样价下的实际投入替换成本与应付工资，按显式 output cost share 或参考产值份额
分摊；金银法定发行品不使用零售成本锚。供给不足时成本锚置信度随供给降低，避免没有成交的
理论成本强推价格。无需求、无供给、无库存的商品缓慢回归目录默认价。

价格变化先应用 good-specific `price_adjust_q16` 与单日 max rise/fall，再以
`daily_change*N` 做确定性一阶冻结积分，最后应用绝对 min/max。该算法避免对每个
market-good 做 N 次反馈或幂运算；误差由版本化 `frozen_sample_adaptive_price_v2`
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

只有 stable ID `gold`、`silver` 可配置正发行值。金银后续交易是普通 cohort 间转账，不再次
mint。周期流物资在 utility prepass 进入 MarketStore，同周期工业输入照常计入
`production_inputs_consumed`；周期末剩余量计入 `cycle_flow_discarded`，因此 goods 守恒为：

```text
closing_stock = opening_stock + explicit_stock_delta + accepted_output
                - household_consumption - construction_inputs
                - production_inputs - cycle_flow_discarded
```
