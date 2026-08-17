# Market V2 / Price V4 定点数、需求曲线与守恒账本

## Price V4 参考价值加法积分

令 `p` 为当前价格、`a_up=max(default_price,cost_anchor_price)`、`a_down=max(1,p)`，
`x` 为供需、库存、短缺和成本压力经弹性及 `price_adjust_q16` 调整后的日变化率。
对冻结的 `N` 日周期：

`r = clamp(x, -max_fall, max_rise) * N`

`p_market = p + (a_up if r >= 0 else a_down) * r`

上涨刻意不使用 `p` 作为乘数，因此相同短缺压力不会随当前价格复利放大；下跌改用当前价格，
使每期降幅受商品自身价格尺度约束，较高的生产成本锚不会把清仓压力放大成越过当前价格的跳水。
若需求、供给和库存全为零，再独立执行
`p_next = p_market + (default_price-p_market)*min(1, alpha*N)`。
价格没有玩法上下限；`PRICE_NUMERIC_GUARD_MIN/MAX` 仅防止定点整数溢出。

## 数值 ABI

人口为整数 `i64`；资金尺度 10,000；物资尺度 1,000；价格是每完整物资单位的
10,000 资金尺度；比例/满足度为 Q16；率/余数 ABI 为 Q32。尺度写入 schema V2 存档，
改变尺度必须显式迁移。权威状态不保存浮点数。

## v16 企业现金流

提款溢价为 `ceil(principal * 3277 / 65536)`，仅在提款时计算一次；新提款与旧债合并并把期限
重置为六个本格周期。每期应偿额为 `ceil((principal + premium) / terms_left)`，先本金后溢价。
结算顺序为实物投入、产出销售、基础工资、债务、本期奖金、家庭消费。经济收益为现金收入加
实际自产生活价值；现金自由流不含实物收入，因而实物价值不能产生偿债现金。贷款和投入购买是
两笔相反的资金转移，不计铸币或销毁；坏账只移除债权状态，不改变现存货币。

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

adaptive 的 living/local target 还受日口径企业可负担上限约束：

```text
daily_operating_budget = full_capacity_daily_revenue / (1 + target_margin)
daily_wage_pool = max(0, daily_operating_budget - full_capacity_daily_inputs)
affordable_wage_per_employee = daily_wage_pool / employee_slots * wage_income_cap_ratio
```

目录参考工资仍是最低报价；该上限只防止 epoch 总收入被误当成单日收入，并为停产恢复提供同口径反事实报价。

生产只按业主现有资金购买物理投入，不预付工资；产出出售后，同一 owner 对全部 role 比例支付。
最终欠薪只形成诊断和取消奖金，不追溯停止本期生产。随后，
`25% * max(0, revenue - input - base_due - target_owner_profit)` 成为员工奖金池。
基础工资与奖金都是 cohort 间转账，既不改变总资金，也不进入 explicit mint/burn。

企业采购和实际生产使用两个容量：

```text
hardness                = input_required_q16 / Q16_ONE
input_floor             = 1 - hardness
input_bound             = input_floor + hardness * local_input_stock_coverage
input_purchase_scale    = max(0, realized_capacity - input_floor) / hardness
purchase_intent_capacity = min(available, owner employment, each critical role employment,
                               owner input-cash coverage, natural-resource coverage)
realized_capacity        = min(purchase_intent_capacity, each input_bound)
business_demand          = unit input * building_days * input_purchase_scale(purchase_intent_capacity)
realized_profit_margin   = (sales - input cost - base wages due)
                           / max(input cost + base wages due, MONEY_SCALE)
```

`input_required_q16=65536` 是旧硬互补：缺任一输入则实际产能为 0；软输入把缺货影响限制在该槽位的
hardness 权重内，例如 `32768` 的工具槽在无库存时仍保留半产能，库存/现金足够时恢复满产。
本地缺货不把采购意图归零，只把实际产能压到库存瓶颈；无人、无输入资金、资源枯竭或
`SUSPENDED_LOSS` 则两者均为零。输入购买量使用 fixed-point 比例缩放，但只要完整物理需求为正且购买比例为正，实际购买/成本数量至少为 1；因此硬输入不会在极低产能下被向下截断成零投入免费生产。
实际有经营成本的利润率连续三周期 `<= -25%` 后停产；无生产且无成本的纯缺货周期不累计。停产期用当前价格、最低有效输入成本和合同工资计算反事实利润，连续
两周期 `>= +10%` 且业主资金覆盖一栋一周期成本后恢复。

商人采购预算为：

```text
target_inventory_days = 60 days * good_inventory_target_ratio
smoothed_supply_floor = offered_daily_output * (1/2 if survival_good else 1/4)
protected_daily_demand = max(feasible_household_and_business_demand,
                             realized_withdrawal_ema,
                             smoothed_supply_floor)
if protected_daily_demand == 0 and export_ema == 0:
    protected_daily_demand = offered_daily_output  # 首周期供给探测
target = (protected_daily_demand + export_ema) * target_inventory_days
gap = max(target - current_stock, 0)
procurement_budget = opening_merchant_cash * 87.5%
priority = 1 + survival_priority + shortage_pressure + input_reserve_shortfall
good_budget_share = min(procurement_budget, sum(gap * buy_price))
                    * (gap * buy_price * priority)
                    / sum(gap * buy_price * priority)
```

权重只改变有限现金的购买顺序，总预算仍由真实缺口价值封顶；配置库存天数和目标量级不因本轮调整缩小。

默认比例分为：生存必需品 1.50（90 日）、重要民生/医疗能源 1.25（75 日）、
普通原料与工业品 1.00（60 日）、奢侈品约 0.667（40 日）；`cycle_flow` 为 0。
比例在目录加载时一次性编译成 Q16 有效天数，市场热循环仍只读取 dense 整数列。

预算余数按稳定 good ID 和 building group 顺序落位；金银铸币结算不受普通采购预算限制。

普通商人采购完成后，对正常目标库存尚未填满的耐储余货按冻结本地零售价的 20% 托底；`cycle_flow` 余货也会在本周期内先获得低价清算/托底机会，但不会跨周期留存在市场库存：

```text
supported_qty = min(offer_sellable - normal_merchant_purchase,
                    remaining_target_inventory_gap)
support_money = max(1, floor(supported_qty * frozen_retail_price / (GOODS_SCALE * 5)))
if storage_mode != cycle_flow:
    market_stock += supported_qty
owner_funds += support_money
explicit_money_mint += support_money
```

托底不扣商人资金。`production_output_supported` 和 `producer_support_money_issued` 分别报告接受量
和发行额；超过目标库存的普通余量与周期流边界剩余量都进入真实 discard sink。

每次提交严格校验：

```text
country_research_goods_consumed = max(0,
    research_consumed_total_at_close - research_consumed_total_at_epoch_begin)
```

```text
closing_population = opening_population + explicit_population_delta
closing_money      = opening_money + explicit_mint - explicit_burn
closing_stock      = opening_stock + explicit_stock_delta - consumed_goods
                     - country_research_goods_consumed
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
need(priority, base_qty, wealth elasticity/min/max,
     price_quantity_elasticity/floor, quantity_env_curve)
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

需求量由人口、人均财富幂函数、民族 need factor、sample-day 环境曲线、周期天数和 need 总量价格
因子相乘。variant 权重由基础偏好、价格弹性和偏好环境曲线决定，再以稳定整数份额拆分 need；其
归一化 composite 价格分数再按 `price_quantity_elasticity_q16` 求幂并应用
`price_quantity_floor_q16`。这一因子按 market×need 预计算，不在 cohort hot loop 重复求幂。
主食与衣着使用较低弹性和正下限，仍随市场价与人均存款缩量；蛋白质及非刚需没有刚性购买下限，
当所有替代品都昂贵时可以接近零。一个 variant 的
多个 components 是互补 bundle，实际 bundle 数取各 component 可供量的最小值；同一
need 的 variants 是替代品，首选不足只允许一次 fallback，防止组合搜索爆炸。

主食、蛋白质、蔬果和衣着另算冻结生存量：

```text
survival_required = population * survival_household.base_qty * N
survival_required *= ethnicity_factor * sample_day_environment_factor
clearing_desired   = max(elastic_desired, survival_required)
```

它不乘财富或价格 composite。生产者自留和死亡分母读取同一结果，避免销售收入改变最低生存标准。

资金和库存短缺使用累计前缀商：

```text
allocation_i = floor(prefix_i * available / total)
             - floor(prefix_(i-1) * available / total)
```

顺序固定为 market、cohort slot、need priority、variant、component。该方法精确耗尽可用
额度且无逐单位余数循环。

## 生存、出生、劳动与死亡

目录仍保留主食、蛋白质和蔬果三个内部子 need，以表达营养、价格和技术替代；生存判定把它们
按实际 desired/filled 数量合并为一个食品篮子。衣着单独计算，数量先乘 17 点温度曲线；最热端
允许曲线为零，因此无需衣着也视为满足。权威 Q16 值为：

```text
balanced_food_sat = sum(food_filled) / sum(food_desired)
best_food_sat = max(staple_sat, protein_sat, produce_sat)
food_sat     = max(best_food_sat, balanced_food_sat)
clothing_sat = clothing_desired == 0 ? 1 : clothing_filled / clothing_desired
cold_exposure = max(clamp((0.5 - temperature) * 2, 0, 1), snow_cover)
cold_clothing_ceiling = 1 - cold_exposure * (1 - clothing_sat)
survival_sat = min(food_sat, cold_clothing_ceiling)
starvation_deficit = max(0, starvation_satisfaction_threshold - survival_sat)
```

`survival_sat` 即 `SAT_DIM_SUBSISTENCE`，也是 `needs_satisfaction` 的权威值。
它**只**参与 `starvation_deficit`；饿死是生理事实，税负、储蓄和聚落发展都不得致死。
出生率读综合满意度，但格级 sat 进入 `K_eff`，cohort 只乘残差，避免把心情乘两次。
未解锁的住房/卫生 need 不进物资族分母，也不另开拥挤死亡：

```text
K_geo     = max(K_floor, K_habitat + K_resource)
surplus   = Σ bindable family_weight × family_cover / Σ bindable family_weight
sat_cell  = Σ pop × class_weight × rescale(composite) / Σ pop × class_weight
mix(x, e) = lerp(1, x, e)
support_ema = EMA(mix(surplus, surplus_elasticity) × mix(sat_cell, sat_elasticity))
K_eff     = K_geo × support_ema
load      = P / K_eff
fertility_land = 1                          if load ≤ soft_start
               lerp(1, death/birth, t)      otherwise
cohort_sat_residual = clamp(rescale(cohort) / sat_cell)
effective_birth_rate_q32 = birth_rate_q32 × fertility_land × city.birth_factor × cohort_sat_residual
expected_births_q32 = population × effective_birth_rate_q32 × epoch_days
```

`rescale` 仍按 `satisfaction_birth_reference_q16` 重标定。`K_geo` 用冻结地貌/植被/气候/河湖
与已解锁食物建筑的最优产量；`support_ema` 进 PKEC v36 与 `state_hash`。
饥饿死亡公式不变，只读 `SAT_DIM_SUBSISTENCE`。

`composite_sat` 的八维度定义、权重契约与生存闸门见
[综合满意度运行时](./satisfaction-runtime.md)。

周期开始时仍存活人口先就业和生产，不用上周期满足度削减劳动力。
职业默认出生率为每日 Q32 `2353407`（约 20.0%/年），自然死亡率为 `294176`（约 2.5%/年），
完全满足时净增长约 17.5%/年，健康人口在 `P ≪ K_eff` 时理论翻倍时间约 4.3 年；贴上格承载力后出生落到更替
（`death_rate/birth_rate`）。同一 cell
内按 ethnicity 汇总 `expected_births_q32`；整数部分直接出生，Q32 小数部分写入每格每民族的
`birth_residual_q32` 并跨周期累计，由 PKEC 持久化。
新生人口在结构提交末尾合并到 `unemployed|eth`，资金、收入和就业均为零。

默认饥饿满足度阈值是 50%；
低于阈值的缺口乘 `starvation_death_rate_q32`，与 cohort 的既有 Q32
死亡率及 `demography_residual` 合并后按周期天数确定性取整。死亡计入 `births/deaths` 和人口
守恒；每个仍有市场库存的地块至少保留一名人口，避免产生无所有者库存。

## 价格

每个商品以 `period_demand/N` 更新居民需求 EMA；effective alpha 为
`min(1, daily_alpha*N)`。Price V3 的总需求是居民需求 EMA 与稀疏企业投入需求 EMA 之和；
供给使用建筑实际 offer（含托底入库和周期流丢弃、排除业主留用）EMA。每个活跃 `(cell, good)` 只维护一条稀疏信号，
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
发行品不使用零售成本锚。库存低于目标且仍有需求时，成本锚同时成为受单日最大涨幅约束的价格
下限；库存已经堆积时仍只保留软压力，不阻止降价清仓。供给不足时软成本项置信度随供给降低，
避免没有成交的理论成本无条件强推价格。
无需求、无供给、无库存的商品缓慢回归目录默认价。

企业在 ACTIVE 状态下按上一周期 `sold / (sold + discarded)` 调整下一周期计划利用率，并使用
`supply_price_elasticity_q16` 作为响应增益。丢弃率不超过 1% 时视为定点舍入噪声并向满产恢复；
任一产出的 `max(0, stock - production_input_reserve)` 低于 `max(1 商品单位, max(realized_withdrawal_ema, demand_ema) × N)` 且短缺率至少 12.5% 时也主动向满产恢复。真实丢弃或托底后仍高于正常目标的
库存会按市场吸收能力收缩利用率。耐储商品保留 1/32 的探测产能，易腐/周期流商品保留 1/6；生存食物组再按同一业主人口跨过饥饿阈值所需的自留量计算动态利用率下限，并取较高者。只有连续严重亏损状态机能完全停产。最低生存自留按业主实际生产的单组分食物/衣物重新归一化，不向无法自产的替代品分摊配额。

利用率的可负担需求为居民 `demand_ema + business_demand_ema`。短缺恢复比较该总需求与
`realized_withdrawal_ema`，而不是只读取居民 `last_shortage_q16`；企业专用工具和中间品即使没有
家庭需求，也会按真实下游采购缺口恢复供给。已实现利润的成本分母包含实际到岗业主在本周期的
最低生活费，以及输入成本和应付基础工资；奖金仍是利润分配，不在奖金计算前重复扣除。

生产投入预留先对同组互补投入求共同可执行比例，按该比例同步缩放每项预留；同一商品被多个槽位选中时先合并需求，防止超额锁库。非生存产出若消耗生存食物，则整套投入不在家庭清算前预留，家庭先满足生存需求，建筑生产阶段再使用余量。`production_input_reserve_shortfall` 累计期望预留未能组成完整配方的差额，以及本期生产消耗后实际库存低于既定预留的差额。

价格变化先应用 good-specific `price_adjust_q16` 与单日 max rise/fall，再以
`daily_change*N` 做确定性一阶冻结积分，最后应用绝对 min/max。该算法避免对每个
market-good 做 N 次反馈或幂运算；误差由版本化 `production_income_consumption_v12`
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
                 - production_inputs - production_output_discarded
                 - cycle_flow_discarded - country_research_goods_consumed
```

所有生产业主按本 cohort 的普通 desired need quantity 和正常 variant 得分份额留用自产物资；
多组件 variant 按组件分别判定：业主自家产出的组件自留，未产出的组件仍走市场购买。食物额外留足饥饿阈值热量，并先匹配原消费计划的
精确 variant；剩余自产食物可跨三类食品计入紧急生存热量，但不改变各 need 的普通满足度或
最差 need。衣物另按冻结温度/积雪造成的寒冷暴露反推最低比例。
剩余商品进入本地市场，与其他 cohort 共同清算。
留用仍是同一周期内的生产 source 与 owner consumption sink：实际消费量同时计入
`production_output_retained` 和 `owner_output_consumed`，两项在 goods audit 中对消；未消费留用品
直接进入 `production_output_discarded`，不进入 closing stock。自用不产生现金支出或商人结算，
但按冻结零售价计入业主 `epoch_in_kind_income`，并按商品加入 `realized_withdrawal_ema` 的实际吸收量。

居民预算清算前，运行时按每个 ACTIVE owner-lot 的建筑数、周期天数、已到岗业主比例、计划利用率
和冻结单位投入成本计算下一周期营运资金。该金额仍属于 owner cohort，只从本期家庭下单预算和
最终支出上限中扣除，不产生资金转移；`owner_working_capital_reserved` 报告本周期受保护总额。

生产投入另有商品侧预留。运行时按建筑数、周期天数、计划利用率和每槽 `input_required_q16`
向上取整下一周期实际需要购买的物理投入；当计划利用率低于软输入的无货产能底线时，该槽不预留。
对每个 input slot 优先选择库存覆盖率最高、再按冻结有效价格和 stable ID 决胜的可用候选；同组互补输入按共同可执行比例缩放后聚合为稀疏 `(cell, good)` 预留：

```text
household_available_stock = max(0, stock - production_input_reserve)
merchant_inventory_target = max(normal_target, production_input_reserve)
exportable_stock           = max(0, stock - production_input_reserve)
```

预留本身不改变库存所有权，也不是 goods sink；居民和国内贸易只能清算预留以上的库存。缓存由建筑
与周期计划确定性重建，不进入 PKEC 字节布局。报告和 CSV v10 发布预留总量、期望与结算末受保护库存之差及逐商品家庭
可用库存。

## 2026-07-20 endogenous owner investment

价格驱动的资本评估只允许已满员 industrial owner-lot 扩建。collector 的容量由自然资源
可行性和显式建设策略决定，service 由人口/贸易拓扑策略决定。industrial 候选门槛为：

```text
margin_gap_q16 >= 0                         # 已达到建筑自身 target margin
planned_utilization_q16 >= 0.75
demand_pressure_q16 >= 0.125
demand_ema - offered_supply_ema >= unit_output / 2
projected_owner_income >= owner_living_cost * 1.10
target_income >= source_income_per_capita * 1.125
required_capital = construction_cost_at_local_prices
                 + input_cost * operating_cycles
                 + one_cycle_base_wages
                 + owner_living_cost * 30
source_funds_per_capita >= required_capital
```

`demand_pressure_q16` 取成交短缺率与正需求缺口比例的较大值。出资人口按 cohort 人口比例携带
资金转入目标业主 signature，随后复用 BUILD：建材从 merchant-owned stock 扣除，建设款从业主
cohort 转给本地商人。每地块每个评估窗口至多一座；service 不参与。零建材只适用于 collector，
industrial 仍必须有显式建材配方。goods audit 继续为：

```text
closing_stock = opening_stock + explicit_stock_delta + accepted_output
                - household_consumption - construction_inputs
                - production_inputs - production_output_discarded
                - cycle_flow_discarded - country_research_goods_consumed
```
## 2026-07-18 owner livelihood and capped procurement formulas

For an owner signature in one cell, the business cash buffer is:

```text
required_household = base_living_cost_per_owner_day * filled_owner * epoch_days
owner_cash_reserve = min(required_household, owner_cohort_cash / 2)
input_cash_available = max(0, owner_cohort_cash - owner_cash_reserve)
```

Employee base payroll is paid before this buffer is applied. Profit bonuses use
the buffered balance. The viability anchor for an owner lot is:

```text
owner_livelihood = base_living_cost_per_owner_day * filled_owner * epoch_days
viability_operating_cost = paid_input_cost + employee_wage_due + owner_livelihood
viability_income_gap = realized_revenue - viability_operating_cost
```

For each offered good, `purchase_cap` is the value of the remaining unchanged
inventory-target gap at its effective bid. The merchant budget is allocated in
priority-weight proportion, but each allocation is capped at `purchase_cap`.
Cash released by a cap is deterministically redistributed among the remaining
positive gaps. Every debit remains a merchant-to-producer transfer; the existing
bounded producer-support branch is the only mint in this path.
## PKEC v14 capital and demand identities

The production demand identity is
`desired_input = recipe * building_count * epoch_days * planned_utilization`,
`funded_input <= desired_input`, and
`unfunded_input = desired_input - funded_input`. Desired quantities are signals;
only funded quantities can debit merchant inventory and owner cash.

Owner working capital is a deterministic allocation of existing cohort cash.
The allocator protects `min(livelihood, owner_cash / 2)` and the base-payroll
cash gap not covered by frozen expected sales. Input debits, output sales, and
post-sale proportional payroll preserve the existing money ledger.

Entrepreneurship moves one population unit and exactly `required_capital` from
one non-merchant cohort to the target owner cohort. Any proportional cash carried
by population movement is corrected by an explicit transfer or refund before
construction. Construction then debits real goods, pays real merchant cohorts,
and records every population, funds, stock, expense, and income event leg.

## PKEC v15 rolling audit boundary

Each due cell still applies the same fixed-point five-day formulas. Staggering
changes only which cells transact on a simulation day. Trade escrow and transit
goods remain part of global money/goods totals and daily arrivals transfer those
stocks without waiting for a local settlement. Population, money, and goods
errors must be exactly zero after every daily publish, not only after all five
phases have run.

## PKEC v15 production parallel reduction

Parallel building production does not change any Q16, money, goods, resource,
wage, merchant, support-mint, or bullion formula. Each due cell owns disjoint
authoritative lanes, so workers apply real transfers directly without atomics.
Only cell-local saturation counters, additive diagnostics, retained-output rows,
cashflow drafts, and trace drafts enter `ProductionResult`. Native then reduces
results in stable cursor order with the existing saturating operators; the
working-capital error bound remains a maximum rather than a sum.

Consequently the audit identities are unchanged:

```text
population_error == 0
money_error == 0
goods_error == 0
explicit_money_mint == producer_support_money_issued + bullion_money_issued
```

Worker dispatch is not permission to approximate cash, goods, population, or
resource conservation. Controlled approximation remains limited to the already
documented fixed-point planning bounds and rolling observation latency.

## 2026-07-20 investment viability and rolling employment diagnostics

Employment totals are derived per cell and per rolling epoch. Recomputing one
cell first removes that cell's cached contribution only when the cache belongs
to the current epoch, then adds the replacement. Structural reconciliation may
therefore run on a non-due cell without subtracting a contribution that has not
yet been published; global owner jobs, employee jobs, and unemployment remain
nonnegative derived diagnostics and do not enter PKEC or the state hash.

Endogenous investment reviews each `(cell, building_type)` as one aggregate.
For each output, installed daily capacity is:

```text
installed_capacity = unit_output_per_day * installed_building_count
ordinary expansion requires demand > installed_capacity * 1.10
survival expansion requires demand > installed_capacity * 1.05
```

Any positive marginal output deficit with positive projected utilization may
enter economic viability evaluation. Historical sell-through is an absorption
estimate for projected cash revenue, not an independent 80% entry gate;
discard is a production/utilization diagnostic, not an independent 10% veto.
Pending construction, suspended capacity, owner vacancies, materials,
resources, input chains, sponsor cash, and installed-capacity sufficiency retain
distinct rejection codes. A suspended owner lot retains no production claim,
hires no employees, and produces nothing. An active owner vacancy is resolved
only by the employment pass and cannot reserve or transfer investment capital.

For one proposed building at planned utilization `u`:

```text
variable_cost = (daily_inputs + daily_employee_wages) * u
owner_livelihood = owner_daily_living_cost * owner_slots
operating_cost = variable_cost + owner_livelihood
required_revenue = operating_cost * (1 + target_operating_margin)
profit = revenue - operating_cost
payback_days = ceil(required_capital / profit)
required_capital = construction_cost
                 + daily_inputs * operating_cycles * epoch_days
                 + daily_employee_wages * epoch_days
                 + owner_livelihood * 30
```

Revenue must cover owner livelihood and the target markup over operating cost;
the former `profit / revenue` comparison is not used. For each cash-qualified
same-ethnicity cohort:

```text
current_income = max(income_ema, 0) / cohort_population
income_gain = projected_owner_income - current_income
investment_probability_q16 = clamp(income_gain / projected_owner_income, 1, 65536)
```

Only a positive `income_gain` is eligible. The probability roll is a stateless
deterministic hash of `seed/day/cell/building_type/source_signature`, so replay,
save/restore, and worker/scalar behavior remain identical. Same-profession
owners may reinvest directly. Cross-profession winners move one person to the
configured owner signature; the final local merchant cannot move. All arithmetic
remains saturating fixed point and every approved build still performs real
cash, construction-stock, and merchant-income transfers.

### Marginal-output investment signal (v6)

For every building output `g`, investment derives persistent pressure `P_g`,
single-building utilization `U_g`, current sellable output `Q_g`, merchant cash
purchases `M_g`, and discarded output `D_g` on the same sparse `(cell, good)` lane:

```text
driver_strength_g = max(P_g, U_g)
sell_through_g = M_g / Q_g
discard_g = D_g / Q_g
```

The driver is ordered by strength, pressure, utilization, then stable good ID.
The driver must have a positive marginal deficit and positive utilization.
Producer support and owner retention never enter `M_g`. Expected revenue sums
each output after applying its own historical merchant absorption, or its
persistent deficit when no history exists. Thus weak sell-through can still
make the margin or payback calculation fail without being treated as proof of
unprofitability by itself. Discard remains visible to utilization feedback and
diagnostics. `investment_min_shortage_q16` and
`investment_min_utilization_q16` remain serialized policy fields for PKEC
compatibility but no longer gate candidate entry or normalize ranking.

## ACTIVE owner job income reallocation

After unemployed-pool hiring, remaining ACTIVE non-service owner vacancies use
the same relative-income probability without creating construction or capital flow:

```text
projected_owner_income_per_day =
    max(0, frozen_expected_revenue - frozen_inputs - full_employee_wages)
    / (full_owner_slots * epoch_days)

owner_job_probability_q16 = clamp(
    (target_income - source_income) / target_income, 1, 65536)
```

Targets require positive projected income; sources must be ACTIVE, available,
non-service, same-ethnicity groups with at least one owner. The deterministic roll hashes
`seed/day/cell/target_group/source_group`. A group can participate in at most one
successful movement per epoch. Same-profession movement changes only group fill;
cross-profession movement transfers one cohort member and its proportional funds,
income EMA and slow income baseline EMA, current income/expense/in-kind income,
epoch tax paid and subsidy received, demography residual, and every satisfaction
column (composite, the eight dimensions, and the worst dimension). No money or
goods are created, consumed, or transferred between accounts by the job decision
itself. When two employers are equally profitable, hire order breaks the tie on
the owner cohort's previous-epoch composite satisfaction; employment runs before
the market pass, so that value is always last epoch's and never introduces a
same-epoch cycle.

## CSV v12 derived balance formulas

The opening-cash ceiling is not a procurement demand measure. CSV v12 reports:

```text
procurement_opportunity = sum(inventory_gap_good * producer_buy_price_good)
procurement_allocated = min(merchant_cash_after_reserve, procurement_opportunity)
procurement_unspent_allocated = max(0, procurement_allocated - procurement_spent)

in_kind_value = retained_quantity_consumed * committed_retail_price / GOODS_SCALE
cash_expense_coverage = cash_income / cash_expense
livelihood_coverage = (cash_income + in_kind_value) /
                      (cash_expense + in_kind_value)
```

In-kind value is a welfare diagnostic, not a monetary transfer. It does not change
cohort funds, merchant funds, the money audit, PKEC v15 bytes, or the state hash.

Utilization still follows realized sell-through, but high discard accelerates the
existing response. A discard rate of at least 25% applies a response floor of 0.75;
at least 50% applies a response of 1.0 when no active shortage recovery is required.
A real shortage recovery signal retains priority, and the existing survival
utilization floor remains authoritative.

## Healthy subsistence and effective-supply investment

```text
healthy_retention = survival_required * survival_production_target_q16 / Q16
livelihood_cash_charge = max(0, owner_livelihood - consumed_retained_frozen_value)
production_input_budget = owner_cash - uncovered_wage_commitment

output_deficit = max(0, household_demand_ema + business_demand_ema
                        - offered_supply_ema)
entry_output_utilization = min(1, output_deficit / candidate_daily_output)
input_period_supply = max(0, stock - existing_input_reserve)
                    + offered_supply_ema * epoch_days
input_coverage = min(1, input_period_supply / candidate_period_input)
soft_input_bound = 1 - required_share + input_coverage * required_share
entry_utilization = min(entry_output_utilization, every soft_input_bound)
```

The frozen-value credit is assigned only when retained goods are physically consumed.
It is capped by owner livelihood when computing realized margin and never changes cohort
funds, merchant funds, cash income/expense, or the money audit. Household settlement
already preserves the production input float, so production no longer subtracts a second
livelihood reserve from that same cash.

## Price inventory and numeric guards

```text
price_inventory_days_q16 = min(good_target_inventory_days_q16,
                               epoch_days * Q16)
price_inventory_target = (household_demand_ema + business_demand_ema)
                         * price_inventory_days_q16 / Q16
inventory_pressure_q16 = clamp((price_inventory_target - stock)
                               / max(GOODS_SCALE, price_inventory_target), -1, 1)

merchant_inventory_target = protected_daily_flow
                            * good_target_inventory_days_q16 / Q16
final_price = clamp(rate_limited_composite_price,
                    max(1, good.min_price),
                    min(INT32_MAX, max(max(1, good.min_price), good.max_price)))
```

The price target is derived transiently and is not merchant inventory authority. The
merchant target retains the full configured horizon. Catalog `min_price/max_price` clamp
normal prices in addition to the integer-safety guards. The production cost anchor is
still a dynamic soft floor and may lift an underpriced active output only within the
configured price-rise rate.

## Flow replacement procurement and producer settlement

The merchant inventory target remains the long-horizon stock authority. Procurement now
uses projected post-cycle stock so recurring withdrawals can be replaced before current
stock falls below the target:

```text
forecast_daily = max(realized_withdrawal_ema,
                     household_demand_ema + business_demand_ema)
                 + export_ema
cycle_withdrawal = forecast_daily * epoch_days
projected_stock = max(0, current_stock - cycle_withdrawal)
restock_quota = max(0, merchant_inventory_target - projected_stock)

survival_high_water = merchant_inventory_target * 1.20
continuity_quota = min(sellable, cycle_withdrawal,
                       max(0, survival_high_water - projected_stock))
procurement_quota = min(sellable, max(restock_quota, continuity_quota))
```

`continuity_quota` applies only to survival food and clothing. Stock above the high-water
band receives no continuity purchase, so the mechanism replaces genuine flow without
creating unlimited inventory accumulation.

Existing merchant cash is allocated in strict transient tiers: survival replacement,
production-input reserve gaps, then ordinary inventory. Each tier retains the existing
priority-weighted capped redistribution. After each good receives a quantity and cash cap,
that good's merchant purchase and bounded producer support are distributed among offers in
proportion to sellable quantity using stable prefix rounding. Total quantity, cash, stock,
and mint values remain unchanged by the split and deterministic across worker/scalar paths.

For owner-signature working capital, survival producers receive the full input cost of the
currently executable, expected-to-sell scale before ordinary score filling. Executable scale
is capped by the existing renewable harvest/standing-resource availability and by the same
forecast procurement quota. A physically blocked or overstocked producer therefore cannot
consume pooled owner cash merely because its output is classified as survival.

## Suspended producer restart and liquidation gate

```text
settled = last_output > 0 or last_input > 0 or last_resource > 0
          or last_resource_generated > 0
advance_suspension = (settled and realized_margin <= severe_loss_threshold)
                     or (filled_owner > 0 and not settled)

restart_executable = physical_inputs_available
                     and natural_resources_available
                     and financing_available
advance_liquidation_review = restart_executable
                             and expected_margin < restart_margin
```

Suspension sets production, owner demand, employment, and input demand to zero but does not
remove the building. A profitable, executable restart records `pending=ACTIVE` and becomes
active at the next frozen settlement boundary. Non-executable reviews reset the consecutive
failure count. A permanently unprofitable suspended group is liquidated only after 73 failed
five-day reviews (approximately 365 days); service buildings do not evaluate these formulas.

## Production climate capacity

All profile inputs and results use Q16 and truncate toward zero through the
shared saturating fixed-point helpers:

```text
fit(signal, optimum, tolerance)
  = clamp(Q16_ONE - abs(signal - optimum) * Q16_ONE / tolerance,
          0, Q16_ONE)

temp_fit = fit(cell_temp_30d, temperature_opt, temperature_tolerance)
water_fit = fit(cell_plant_available_water, water_opt, water_tolerance)
raw_fit = min(temp_fit, water_fit)
bounded_fit = max(profile_floor, raw_fit)
climate_capacity = Q16_ONE
                   - exposure * (Q16_ONE - bounded_fit) / Q16_ONE

total_capacity = min(labor_capacity,
                     input_capacity,
                     capital_capacity,
                     resource_capacity,
                     climate_capacity)
```

Tolerance must be positive; optimum, floor, exposure, signals, fits, and
capacity remain in `[0,Q16_ONE]`. A missing profile is exactly `Q16_ONE`.
`climate_lost_output` is the nonnegative output difference between the feasible
pre-climate capacity and total capacity, after the existing output and Modifier
factors. Climate creates no goods or money and cannot increase baseline output.

## Renewable harvest budget

All quantities below use resource fixed units. For renewable resource `r` in
cell `c`, the daily production and investment budget is:

```text
reserve_floor = frozen_reserve[c,r] * resource_min_reserve_q16 / Q16_ONE
harvestable = max(0, reserve[c,r] - reserve_floor)
yield_biomass = min(ecology_capacity[r] / 8, harvestable)
safe_yield_daily = yield_biomass * ecology_growth_q16[r] / Q16_ONE
                   * resource_safe_harvest_q16 / Q16_ONE
epoch_extract_budget = safe_yield_daily * epoch_days
```

All `extract` edges in the same `(cell,resource)` lane share the epoch budget;
`capacity` edges use standing reserve and do not spend it. Investment subtracts
peak daily extraction committed by installed buildings, pending construction,
and candidates already allocated in the same portfolio. Non-renewable entry uses
`reserve / resource_min_horizon_days` as its daily budget. A zero safe-harvest
factor disables the production budget and investment runway gates.
