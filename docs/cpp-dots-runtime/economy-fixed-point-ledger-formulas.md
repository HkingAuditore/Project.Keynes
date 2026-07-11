# Market V2 定点数、需求曲线与守恒账本

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

BUILDING_GRAPH 在 Market V2 后追加固定工资转账：

```text
wage_due = filled_employee_jobs * wage_per_employee_per_day * epoch_days
wage_paid = min(owner_funds, wage_due)
owner funds/expense -=/+ wage_paid
employee funds/income += stable_prefix_share(wage_paid)
```

这是 cohort 间转账，既不改变总资金，也不进入 explicit mint/burn。

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

每个商品以 `period_demand/N` 更新需求 EMA；effective alpha 为
`min(1, daily_alpha*N)`。价格压力考虑日均 EMA、库存覆盖与周期短缺率。先应用单日
max rise/fall，再以 `daily_change*N` 做确定性一阶冻结积分，最后应用绝对 min/max。
该算法避免对每个 market-good 做 N 次反馈或幂运算；误差由周期配置显式控制。

cohort income EMA 同样读取周期净收入日均值，effective alpha 为
`min(1, N/8)`。`epoch_income/expense` 保存周期总额。

## 新内容 SOP

- 新 good：新增 `GoodProfile`，配置默认价、上下限、EMA、目标库存、压力权重与日涨跌幅。
- 新职业：新增 `ProfessionProfile` 并指定默认 consumption plan。
- 新民族：新增 `EthnicityProfile` 与稀疏 need modifiers。
- 新 need/bundle：编辑 `NeedProfile`/`ConsumptionPlanProfile`，保证稳定 ID 与上限。
- 新环境影响：新增 17 点 `EnvironmentDemandCurveProfile`，选择四种已捕获 signal。
- 新 native 数学：增加 schema/version、golden、scalar/batch 等价和 microbench，并重编 DLL。
