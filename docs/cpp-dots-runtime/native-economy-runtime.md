# 原生阶层与本地市场运行时（Market V2 / Price V4）

2026-07 的高速合批、认证近似冷却、generation-stamped scratch 和三态
closing audit 契约见
[运行时性能优化契约](runtime-performance-optimization-2026-07.md)。

实现入口为 `gdext/src/economy_runtime.{h,cpp}` 与
`gdext/src/world_ext_economy.cpp`。`DCWorldExt` 组合持有独立
`NativeEconomyRuntime`；动态人口和商品状态不进入 DataCore `_slots`，也不回填
`MapData.goods_*`。

## PKEC v19 就业稳定、企业重整与商人信用（当前）

Endogenous entry uses `endogenous_owner_portfolio_v8`. A reviewed cell keeps
at most four unique building types in a fixed native portfolio, fills at most
25% of each persistent marginal-output gap, and submits one aggregate BUILD
command per selected type. Aggregate willingness is derived once from the
source cohort's projected disposable-income improvement; it never loops over
persons or gives the unemployed profession an explicit priority. Shared
population, capital, merchant credit, construction stock, and driver-good gap
budgets are consumed once across the portfolio. When two or more types start,
no type may exceed 50% of newly planned owner slots.

Candidate entry now requires only a marketable driver with positive marginal
deficit and positive projected utilization. Historical sell-through still
discounts projected cash revenue; shortage and utilization still rank the
portfolio; discard remains a utilization/diagnostic signal. None is an
independent 80%, 10%, 12.5%, or 65% profitability gate. Approval still requires
the configured operating margin and payback plus sponsor capital, construction
materials, input coverage, building conditions, and natural resources.
`investment_min_shortage_q16` and `investment_min_utilization_q16` remain in the
PKEC policy bytes only for compatibility.

Before scoring, the runtime subtracts unused installed capacity and aggregate
pending-construction capacity from the marginal-output gap. Established types
may grow by at most 10% per review; absent types seed at one building. A
non-merchant must gain at least 50% Q16 disposable income to enter the merchant
profession. The test fixture creates one merchant post per populated cell, and
runtime employment protects only the final local merchant.

Recovery liquidation remains behind the existing executable-but-unprofitable
review gate. An approved review now retires only confirmed excess capacity,
capped at 25% of the group per review, and moves the same proportion of
merchant debt to bad debt. Building groups remain aggregate; no per-building
state is introduced.

`NativeEconomyRuntime` 继续单独持有建筑、债务、就业和贸易状态。建筑状态为
`ACTIVE / SUSPENDED_LOSS / RECOVERY_PROBE`；停产组可从本格商人聚合现金池取得仅用于
建设材料或生产实物投入的信用，基础工资后、本期奖金前按本金优先偿还。连续两个成功试产周期
恢复 ACTIVE；连续六次 10 日审查未恢复则整组清算，商栈除外，未偿债务只记坏账。
自产实物收入按冻结零售价持久化到来源建筑，只参与经济收益和岗位选择，不可偿债。
恢复试产的结果在本周期只写 `pending_operating_state`，到该 cell 下一个 frozen
结算周期开始时才提交。失败探针保持本周期 `RECOVERY_PROBE` 的就业与发布状态一致，
随后进入两个本地周期的冷却；探针 owner/employee 只按 probe capacity 招聘。
建筑角色存储重建保留既有 employee fill，新扩容量保持空缺。自然资源容量在就业前压入
`planned_utilization_q16`；零资源 ACTIVE 建筑保留资产和业主席位、释放按利用率缩放的雇员，
若随后进入 SUSPENDED 才释放业主。PKEC writer 为 v19；restore
接受 v19，并将 v18 的 pending/cooldown 默认迁移为 `NONE/0`。

> 2026-07-11 状态：冻结周期错峰版默认 `market_runtime_mode=ACTIVE`、结算周期 5 日。功能、守恒、
> worker/scalar 确定性、移动和 10M cohort 性能门槛均已通过。

## 2026-07-18 石器经济与资源平衡修正

- 国内贸易拓扑只读取 `cell_base_terrain`；气候系统对 `cell_terrain` 的季节性海冰切换不再改变规范化拓扑哈希或重置路线计划。
- `satisfaction_q16` 保持兼容，新增同值的 `survival_satisfaction_q16` 与 cohort 数组别名，明确该指标是食品与气候衣着两者较低值，不代表全部舒适/奢侈需求。
- 石器食物的商品库存比例从 1.5 调到 1.0，即仍维持完整 30 日目标；生产者托底收购和现金保留规则不变，避免采购量断崖式下降。
- 火塘配方为每日 `7000` 植物 + `3500` 肉类 → `12628` 加工食品，肉类为 50% 软约束；打制石器为 `100` 燧石 → `220` 工具；家庭织造为 `120` 采集植物 → `110` 布匹，不再无原料产布。伐木建筑只开采森林，不再反向生成人工林。
- 黄金/白银发行价值为 `800000/50000`；淘金场和露天银矿分别雇用 1/2 名矿工，参考日薪统一为
  `40000`。满产发行收入可覆盖矿工工资、merchant 业主生计与约 14% 目标利润，矿工收入相对当前
  生存消费形成小幅正结余。测试聚落仍把单人非商人职业保留为至少 2 人，以降低出生人口尚未被下周期就业吸收前的短期职业链断裂风险。
- 黏土、盐、石油按地质存量处理，不再自然生成或自发消退；肥沃土壤长期平衡量基本不变，但日变化率降为原来的约 1/20。金矿、燧石和石料初始储量改用 `0.1` 丰度倍率，并同步缩小适宜度系数，防止省级面积倍率造成超长寿命矿床。

## 2026-07-20 内生业主投资

- `building_employment` 仍先从失业池填补既有盈利岗位；资本投资只在既有业主岗位已满后负责新增建筑，不与就业分配争抢同一空缺。
- `building_commit` 每 30 日进行一次资本评估，每地块最多执行一个动作。只有 industrial 建筑可自动扩张；collector/service 继续由资源、国家或显式建设策略决定，避免石器时代因价格上涨自动放大开采。
- 候选建筑必须达到自身配置的目标利润率、计划利用率至少 75%，业主预计日收入至少高于生活成本 10%，且成交短缺或需求 EMA 超过供给 EMA 的压力至少 12.5%。新增一座的需求缺口还必须达到半座日产能。
- 出资者必须与目标业主同民族、来源 cohort 至少保留一人、人均储蓄覆盖全部建材现价和 30 日生活储备，且目标业主收入至少比来源收入高 12.5%。转职人口按比例携带储蓄；BUILD 复用原生建设交易，真实扣库存、向本地商人付款并计入商品守恒。
- 石器打制工坊建设消耗 `1000` 木材 + `500` 燧石；家庭织造棚消耗 `2000` 木材 + `4000` 采集植物。CSV v10 summary 发布建材消耗、候选、业主流动、开工及资金/建材阻塞计数。

## 权威边界

| 数据/行为 | 权威 | 契约 |
| --- | --- | --- |
| cohort、handle、人口、资金、收入/支出、满足度 | C++ `PopulationStore` | GDScript 无逐 cohort setter。 |
| 本地库存、价格、居民需求 EMA、短缺率 | C++ `MarketStore` | 无 per-cell goods component，无匿名市场现金。 |
| 企业可行需求/供给 EMA、实际出库 EMA、成本锚 | C++ 稀疏 `MarketSignalStore` | 仅保存建筑实际引用的 `(cell, good)` 边；实际出库用于商人库存目标。 |
| 国内路线、稀疏贸易信号、订单、货物/现金托管、进出口 EMA | C++ `Trade*Store` | 同一冻结国家内预算化规划；PKEC v19 保存订单/托管/EMA。 |
| 需求、预算、bundle 清算、替代 fallback、商人结算、Price V3 | C++ Market V2 hot loop | 不访问 Godot Object/Callable/Dictionary。 |
| 周期环境快照 | DataCore 环境 slots → C++ Q16 snapshot | 周期 sample day 捕获 temp/moisture/snow/weather，周期内冻结。 |
| catalog 编译 | `EconomyCatalog`/`EconomyFacade` 冷路径 | stable ID 排序后一次性提交 PackedArrays。 |
| 调度和结算屏障 | `EconomyDailySystem`/`WorldClock` | 周期内正常跨日；仅截止日未完成时 same-day catchup。 |
| 查询与存档 I/O | GDScript 薄壳 | Inspector 只读 selected-cell slice-complete snapshot；存档只读 committed boundary，4–16MB byte chunks。 |

不存在大规模 GDScript fallback。原生 ABI 不可用时经济显式 disabled；显式 PROBE 模式
保留 catalog/bootstrap/查询和显式测试能力，但不进入生产 scheduler。

## 2026-07-15 企业与商人现金闭环

- 国内贸易默认 `ACTIVE`；`OFF/PROBE` 仅供显式配置和测试。范围仍是冻结的同一国家、可通行且连通地块。
- 企业采购意图容量取建筑可用性、业主/关键岗位就业率、业主输入资金覆盖率和自然资源覆盖率的瓶颈；实际产能再叠加本地输入库存瓶颈。缺货输入保留受约束的补货意图，但不能产生实际产出。
- `EconomyProfile.building_output_efficiency_q16` 在 native 目录载入冷路径只缩放物资产出列，默认 `131072`（2 倍）；建设材料、日常投入、自然资源扣减、岗位与工资均不缩放。它是运行配置而非目录内容，因此不改变 building catalog hash、运行时状态布局或 PKEC 字节结构。
- 实际利润率按 `(销售收入 - 输入成本 - 应付基础工资 - 到岗业主最低生活费) / max(经营成本, MONEY_SCALE)` 计算。业主生活费只参与企业可持续性判断，不生成额外现金支出；连续三周期不高于 -25% 后进入 `SUSPENDED_LOSS`。停产期间岗位、采购、产出和企业需求全为零；反事实利润连续两周期达到 +10%，且业主可支付一栋一周期输入、基础工资和生活费后恢复。
- 下一周期利用率的可负担需求同时读取居民 `demand_ema` 与稀疏 `business_demand_ema`。库存不足时，以两者之和相对实际出库 EMA 的缺口触发短缺恢复；因此没有家庭终端消费、但被下游建筑持续采购的工具和中间品不会被误压到 1/32 探测产能。
- 商人库存目标使用 `max(可行 household/business 日需求, 实际出库 EMA, 平滑供给下限) + 出口 EMA` 乘 30 日基线和 good-specific 比例后的有效天数；生存食品/御寒衣物的供给下限为供给 EMA 的 1/2，其他耐储品为 1/4，库存天数和目标量级不下调。采购开始冻结现金并保留 12.5%；有限现金按生存品、短缺压力、生产投入 reserve 缺口加权，但总采购预算仍封顶于真实缺口价值，避免“提高优先级”反而造成有钱不买。`cycle_flow` 目标仍为 0。
- `GoodProfile.inventory_target_ratio_q16` 在 catalog 配置阶段预计算为 dense 有效天数列；热循环不做字符串分类或额外目录遍历。catalog 同时保留 legacy `good_target_inventory_days_q16` 兼容列，使编辑器误加载旧 DLL 时仍能完成 economy/population bootstrap；新版 DLL 优先读取比例列。
- ACTIVE owner-lot 在家庭清算前按已到岗业主份额、计划利用率和冻结单位投入成本保留下周期营运资金；该资金仍在 owner cohort 账户内，但不会被本期居民订单花掉。报告发布 `owner_working_capital_reserved`。
- 生产者只保留生存食品健康下限和寒冷条件下最低衣物；普通非生存自产商品全部进入市场。剩余自产食物可作为跨主食/蛋白质/蔬果的紧急热量。实际消费的自用物按冻结零售价计入来源建筑的实物收入而不产生现金，并进入实际出库 EMA；该价值影响经济收益和岗位选择，但不能偿债。
- C++ 按建筑数、周期天数和计划利用率确定性重建稀疏生产投入硬预留。多投入配方先按同一可执行比例缩放，只预留能组成完整配方的数量；缺少任一互补投入时不会继续锁住其他投入。若非生存产出会消耗生存食物，则整套配方让家庭生存清算优先，只能使用清算后的余量。商人目标库存至少覆盖实际预留；居民与国内贸易只能消费/导出 `stock - reserve`。`production_input_reserved`、`production_input_reserve_shortfall` 及 selected-cell/CSV v14 逐商品列用于诊断。缓存不进入 PKEC，可从建筑和市场信号状态重建。
- 正常商人现金不足时，生产者托底只补足正常目标库存的剩余缺口，不再把全部可储存余货无条件入库；超过目标的余量进入真实 discard sink。被托底的数量仍获得冻结本地零售价 20% 的显式发行货币。`production_output_supported` 与 `producer_support_money_issued` 分开报告，货币审计把后者计入 `_explicit_money_mint`。`cycle_flow` 产出不能跨周期存货，但在边界清零前会先获得同周期低价采购/托底机会，剩余瞬态库存再计入 `cycle_flow_discarded`。
- 生成测试经济不再使用职业固定人均资金：每个 cohort 获得按当前气候、族群和默认价格计算的 30 日 `survival_household` 生存金；业主追加两周期最低有效输入成本；商人追加本地产出目标库存资金。
- PKEC v20 是当前 writer：除 v19 的企业三态、债务、投资参数、pending operating state 与恢复冷却周期外，保存 BuildingIdentityStore 与 Economy Modifier domain。v18/v19 可确定性迁移为空 Modifier store；v2-v17 旧档统一明确拒绝。
- `BUILDING_PLAN` 是原生两遍 continuation：第一遍按 active-cell CSR 计算利润、停产恢复和计划利用率，第二遍按相同稳定顺序重建生产投入 reserve。`building_cells_per_slice=0` 确定性使用 256 个 active cell；正值可做平台定标。cursor、生存利用率 floor 和 reserve 构建缓存不保存、不哈希。
- 建筑生产的 owner-retention scratch 只为本格实际出现的 `(owner, output good)` 建立紧凑 lane；owner signature、owner cohort slot 与 lane 都通过 thread-local generation direct map 查询。它不再为每格清零 `owner_count × good_count` 的 target/used/produced 三个稠密矩阵，也不再为每个 offer 线性搜索 owner。lane 仍按稳定建筑组/output 边首次出现顺序建立，生产、保留、offer 和账本提交顺序不变。
- 人口或建筑结构变化后的就业对账使用 thread-local signature/profession generation scratch，只初始化 affected cell 实际出现的 signature、profession 和 role；affected cell 先用 stamp 去重后按 cell 升序处理。该 scratch 不进入 PKEC、状态 hash 或 report，岗位裁剪和人口就业分摊公式不变。
- 业主营运资金缩放使用 8 次确定性整数二分并返回可支付下界，因此绝不透支；最大利用率低估为请求区间的 `1/256`，实际 Q16 未决界由 `working_capital_scale_error_bound_q16` 报告。

## 2026-07-15 价格弹性、成本底线与生态修正

- 消费目录新增 need 总量价格弹性和刚需下限。variant 分数仍负责替代选择；总量因子按 market×need 预计算。主食与衣着保留正下限但仍随价格和财富缩量，蛋白质及非刚需可在全体替代品过贵时接近零。
- 低于目标库存且仍有需求时，生产成本锚通过受单日涨幅上限约束的正向价格压力形成动态软底；库存堆积时下跌按当前价格限速，仍可跌破成本清仓。企业同时按上一周期售罄率缩放下一周期计划利用率，但忽略不超过 1% 的舍入丢弃，并在家庭可用库存不足 `max(1 商品单位, max(实际出库 EMA, 需求 EMA) × 周期日数)` 且短缺率至少 12.5% 时主动恢复。耐储商品保留 1/32 探测下限，易腐/周期流商品保留 1/6 下限；生存食物生产者另按同一业主人口跨过饥饿阈值所需的自留量计算动态下限，取二者较高值。
- 全建筑目录改用默认生活成本和 80% 保守售出率校准。当前石器狩猎营地为 2 个共同经营岗位，日产 `3728/45/23` 野味/生皮/毛皮；采集营地为 2 个岗位、日产 `7000` 采集植物；家庭织造棚为 1 个岗位、日产 `900` 布匹并消耗采集植物。早期砂金/露天银矿由 merchant 所有，均雇用 1 个 miner 岗位；露天银矿日产降为 `1000` GOODS_SCALE，资源扣减为 `200`。
- `audit_economy_content.ps1` 遍历 260 个建筑并检查 80% 售出率盈利、role 工资、生产原料成本不超过商人收购收入的 60%、工具维护不超过 `100 GOODS_SCALE/岗位/日`、工业总投入/总产出不超过 `3:1`，以及 `2:1` 至 `25:1` extract 效率；蒸汽煤铁矿固定复核约 `12:1`。这是 catalog/content 校准，会改变 building catalog hash，但不改变 PKEC 字节布局。

### 2026-07-18 调度、贸易与工资稳定性修正

- `country_daily` 和 `economy_daily` 仅在当日确属提交截止点时动态声明 `deadline_critical`，可绕过一次 tick 内的 frame/strict 启动门槛，但仍受单 slice 与 continuation 上限约束；`must_run` 保持 false。WorldClock 每推进一天后立即重读 country/economy barrier，不能在同一渲染帧越过刚升起的截止屏障。
- 贸易候选数量用交易后源/目的库存重新报价，并以确定性整数二分裁剪为仍满足最小利润率的最大数量；relief 路线允许零价差但禁止负价差。发运前依据最新库存、现金和国家运力二次裁剪。报告增加 `trade_rejected_no_spread`、`trade_rejected_margin`、`trade_quantity_profit_clips`、`trade_relief_candidates`。
- adaptive 工资可负担上限改为日流量：`满产日结算收入 / (1 + 目标利润率) - 日投入` 得到工资池，再除以员工槽位并应用工资收入缓冲比例。停产建筑也使用该反事实报价，避免周期总收入被错当成日收入而把工资放大约 `epoch_days` 倍。
- 野生动物承载力继续随普通适生度下降，但压力死亡只作用于原始温湿适生度最低 25% 的急性区间，消除普通非理想气候的重复惩罚。理想与普通气候的 24 营地五年采集均有回归覆盖。
- 林木改用理想承载量 `1200×100`、1% 日增长和正迁入的 Beverton-Holt 分支；新地图只对适生度最高的 30% 陆地保证 30,000 最低储量。它在低于承载量时自然增长，并通过单伐木场五年持续采收回归。

## PopulationCohort

同一 `(cell, profession, ethnicity)` 只保留一个聚合 cohort。每页 64 lane，字段采用
平行 SoA：`signature_id`、`generation`、`population`、`funds`、epoch income/expense、
income EMA、Q16 满足度、最差 need ID、flags 与预留 residual。外部 handle 是
`(generation << 32) | slot_index`；回收后 generation 加一。

每个人口非零地块必须有商人：

1. 若没有商人，从本地人口最多的非商人 cohort 转出 1 人。
2. 新商人继承民族，资金按人口比例转移。
3. 总人口、总资金不变；同签名自动合并。
4. 一个地块可有多个民族的商人 cohort，库存由它们共同持有。

成交收入按商人人口使用稳定前缀商分配，直接进入商人 cohort 资金与 epoch income；
不存在 `market_cash` 中间账户。商人自身也按其消费计划正常购买。

## MarketStore 与商品所有权

V2 固定一地块一市场，`market_count == cell_count` 且 `cell_to_market[cell] == cell`。
持久稠密矩阵为：

```text
stock[market, good]             i64  # 商人共同拥有
price[market, good]             i32
demand_ema[market, good]        i64
last_shortage_q16[market, good] i32
```

建筑侧价格信号不扩张该稠密矩阵。`MarketSignalStore` 按 `(cell, good)` 排序保存企业投入需求
EMA、实际 offer 供给 EMA 与单位成本锚；key 只来自现有建筑输入/输出边，并在建筑结构变化时
重建且保留稳定 key 的旧值。

库存初始为零；本轮没有生产。开发/测试通过 `ADD_STOCK` 显式命令增加库存，且目标地块
必须有商人。人口归零的地块不得保留库存。

## Need、替代品与互补品

catalog 编译成 CSR：plan→needs、need→variants、variant→components。

- need：优先级、人均基础量、连续财富弹性/上下限、总量价格弹性/刚需下限、数量环境曲线。
- variant：偏好权重、价格弹性、偏好环境曲线。
- component：good 与每份 bundle 所需数量。
- 同一 need 的 variants 是替代方案；同一 variant 的 components 是必须按比例满足的
  互补 bundle。

每 cohort 每日按优先级重置预算和需求。财富是 `funds/population` 相对
`wealth_reference_per_capita` 的连续定点函数，不形成额外身份分桶。民族以稀疏 need
修正表参与数量计算；温度、湿度、积雪和天气强度通过 17 点 Q16 曲线影响数量或偏好。
variant 价格分数先决定替代份额，再形成 market×need 的总量价格因子。主食和衣着保留正下限但
仍会随价格、人均存款缩量；蛋白质与非刚需在所有替代品过贵时可以接近零购买。

## 周期清算顺序

每个本地市场独立执行，数量按冻结周期 N 日累计：

1. 冻结当日价格、环境和 cohort 视图。
2. 计算 need 数量与各 variant 的价格/环境加权份额。
3. 按 need 优先级约束 cohort 可支配资金。
4. 对 bundle 的每个 component 做稳定前缀库存分配，以最短 component 决定 bundle fill。
5. 首选 variant 未满足部分只进行一次同 tick 替代 fallback。
6. 扣买方资金和库存，按商人人口分配收入，发布 need 满足度/最差 need。
7. 以日均居民需求更新 EMA，合并上一周期企业需求/供给与成本锚，用 Price V3 冻结压力的
   一阶 N 日积分更新下周期价格。

household market 在建筑生产、产品出售和收入分配后计算食品/衣着生存满足，执行确定性缺乏
生存资料死亡，并按 cohort 人数、当前生存满足率及职业/民族 Q32 率累计出生贡献。worker 只写
自身 `MarketResult`；主线程按 `cell×ethnicity` 合并为出生结构命令。国内贸易在同一经济
边界的 `trade_settle` / `trade_dispatch` 阶段运行：到货先进入目的库存；新发运等待本地 household
清算完成，并保留最新本地需求目标库存和生产投入 reserve 后才移除源库存并
托管目的商人现金；随后 household market 只使用剩余/已到货状态。出生在结构提交中最后写入
`unemployed|eth`，不生成资金、收入或商品；人口变化后的建筑就业对账只裁剪超额岗位，正常招聘
留到下一次 `building_employment`。完整契约见 [Domestic Trade Runtime](./domestic-trade-runtime.md)。

## 并行与确定性

slice 按连续 market range 切分；每个 worker 只写自身市场行及其地块 cohort。worker
结果先写 `MarketResult`，主线程再按 market 索引归并指标。定点乘除使用 128 位中间
值与饱和计数；短缺、bundle 和商人收入都使用稳定前缀商，无逐单位余数循环。
focused test 必须验证 worker/scalar state hash 完全相同。

## 公共 API

`configure_economy`、`bootstrap_economy`、`submit_economy_commands`、
`economy_should_run`、`run_economy_slice`、`run_economy_slice_compact`、`get_economy_report`、人口/市场 cell
snapshot、reset、分块 save/restore、固定数学 probe 与 state hash。跨边界写入均为平行
PackedArrays；UI 只查询选中地块。

`run_economy_slice` 返回 `report_mode=full`，供普通 daily tick、显式查询、UI 与录制诊断；
same-day barrier continuation 使用 `run_economy_slice_compact`，返回
`report_mode=compact_slice` 和调度所需的 stage/progress/cursor/work、deadline/fatal、committed event
以及当前 trade/publish/building-commit breakdown。compact 路径不计算 `memory_bytes`、商人债务全量和
贸易 transit/escrow 全量统计。两条 API 共用同一 native stage/cursor 和 `DCWorldExt` 提交包装，资源
delta flush、CSV committed capture 与 gameplay event publish 均不绕过；仅返回 Dictionary 形状不同。

`population_cell_summary()` 与 population/market/building selected-cell snapshot
都发布该地块的 `settlement_generation`。人口 Inspector 先用 summary generation
判断详细 cohort/market category 是否可能变化，再对新构建的 category 做内容 hash；
generation 未变时只允许刷新公共 header/score/summary，不得重复构建或 apply 人口明细。
公共区域使用其实际渲染字段的 hash，因此气候或国家摘要更新不受人口 generation 限制。

`trade_plan_ms` 是当前一次 `run_economy_slice()` 中 planner 的墙钟时间，不是 epoch、
simulation day 或进程累计值。未执行 planner 的 native slice 必须报告 `0`；跨 slice
分析直接采样该字段，禁止再用相邻 report 相减。`trade_plan_breakdown_ms` 以
`trade_planning.scan_body / scan_finalize / route_prepare / route_expand /
route_finalize / other` 完整归因该 slice，`trade_plan_breakdown_work` 同步报告扫描 pair、
初始化 source、Dijkstra expansion 和最终候选数；这些字段只用于诊断，不进入 PKEC、
状态哈希或确定性推进决策。

每个 slice report 同时提供 `executed_stage`、`next_stage` 与 `executed_substage`：前者是本次
调用实际支付成本的阶段，`next_stage` 是返回后的 continuation 状态，兼容字段 `stage` 仍等于
`next_stage`。调度器和性能 CSV 必须用 `executed_stage` 归因，禁止把完成 publish 后切换出的
`trade_planning` 当成本来源。`aggregate_publish` 的 `publish_breakdown_ms/work` 只描述当前
slice，按 prepare、精确审计、verify、watermark、trade flow/diagnostics、trade init 与 commit
对账；`publish_cumulative_breakdown_ms/work` 才是本 epoch 累计。分片游标与临时
累加器不进入 PKEC 或 state hash。完整审计、贸易初始化和水位线完成前 `_epoch_active` 保持 true，
save 继续返回 `save_requires_committed_boundary`，半发布结果不成为 gameplay 权威。
`building_commit_breakdown_ms/work` 同样按当前 slice 报告 `review_prepare`、`special_reset`、
`recovery_review`、`construction_commit`、`investment_prepare`、`investment` 与
`finalize`，用于定位该 stage 内的不可抢占尖峰。
`finalize` 内部先完成二次 construction commit 并将 affected cell 去重为升序，再以默认 128-cell
continuation 执行就业对账，最后用独立 slice 清理投资 transient cache 并转入 publish。report 公开
`building_finalize_cells_per_slice`；profile 为 0 时使用该默认值，正值作为兼容覆盖。该私有
phase/cursor 不进入 PKEC v19 或 state hash，batch 边界不改变
岗位裁剪、人口分配和 cell 提交顺序。

建筑结构提交按 `(cell,type,owner signature)` 合批。竣工命中已有 group 时只更新 count 与债务，
不得重建 role、market-signal 或 labor-signal topology；真正新增/删除 group 时，稳定有序旧 group 与
新增尾部做一次线性 merge。每种建筑的有序唯一 input/output good 集与 employee profession 集在
catalog 编译时烘焙，market/labor CSR 按 cell 用 generation stamp 直接生成，并通过双缓冲线性复制旧
EMA，不再创建全局 `(cell,key)` 临时对象或做比较排序。删除 group 的 role/input span 进入按 type
free list，后续同 type 新 group 优先复用。上述 spans、scratch store、stamp 与 free list 都是可重建
transient 数据，不进入 PKEC v19 或 state hash；state hash 按稳定 group/role 逻辑顺序读取权威 lane，
不依赖物理 span 编号。report 通过 `building_structure_count_only_updates/new_groups/removed_groups`、
`building_structure_topology_rebuilds/role_span_reuses/role_span_appends` 以及
`building_structure_group_merge_ms/market_cache_ms/labor_cache_ms` 公开结构路径与成本。

冻结国家快照同时烘焙 country-major 建筑可用位与升序 building-type CSR。`building_available()`
在 ACTIVE epoch 内走 O(1) 稠密位查询，投资目录直接遍历该国 CSR；两者均为 transient cache，
不改变 catalog 顺序、PKEC v19 或 state hash。`building_commit.investment` 与普通建筑图分开使用
默认 96-cell batch，report 公开 `investment_cells_per_slice`；profile 为 0 时自动采用 96，正值
作为确定性覆盖。投资准备只聚合当日同时命中五日
rolling phase 与资本复核 phase 的 cell，非复核 cell 的 owner-vacancy 诊断沿现有 building CSR
直接计算，不构造全 epoch `(cell,type)` 哈希表。

贸易另提供 `capture_economy_trade_topology()` 粗粒度地图输入和分页
`get_trade_orders_for_cell(cell, offset, limit)` 冷查询；禁止跨桥返回全局路线/订单矩阵。
正式地图由 `MapGenerator._setup_economy_runtime()` 在 economy configure 后、bootstrap 前
捕获一次静态邻接、terrain passability 与 move-cost LUT。默认 `trade_runtime_mode=ACTIVE`；
非 `OFF` 模式捕获失败会中止经济初始化，不允许继续运行一个 topology-not-ready 的假 ACTIVE。

调试录制控制面另提供 `start_economy_csv_recording(config)`、
`request_stop_economy_csv_recording()` 和 `get_economy_csv_recording_status()`。它们管理独立的
`EconomyCsvRecorder`，只在成功 committed publish 且资源 delta 已回写后抓取 CSV v16 POD
批次；worker 编码/写盘状态不属于 runtime report、PKEC 或 state hash。状态包含
`captured/written epochs/rows`、`bytes_written`、`queued_batches`、主线程 capture 与 worker
耗时、`buffer_memory_bytes`、路径、`error_code` 和 `first_unrecorded_epoch`。
`start` 的可选 `cell_indices` 为空时沿用 `cell_stride`；非空时经范围校验、排序和去重后成为
本次录制的冻结样本集合，并在状态中报告 `cell_scope`、`sampled_cell_count` 和
`selected_cell_index`。summary 保持全局语义，其余四表按样本 cell 输出。

人口 cell snapshot 在 committed boundary 额外返回 cohort-major CSR 预计需求：
`demand_good_offsets`、`demand_good_indices`、`demand_per_capita_daily` 和
`demand_good_stable_ids`。它复用正式清算的财富、环境、替代品与互补品定点内核，固定
`dt_days=1`，只计算预算/库存约束前的预计单位/人/日。当前地块环境由 `DCWorldExt`
直接读取 DataCore slots；查询只使用局部临时数组，不改变 state hash、report、存档或
持久内存布局。

同一查询还返回 `demand_need_offsets/indices`、`demand_need_variant_offsets`、
`demand_variant_component_offsets`、`demand_component_good_indices` 与
`demand_component_per_capita_daily` 的嵌套 CSR。Inspector 始终以 `demand_good_*` 聚合列作为
商品数量与支出的唯一来源；嵌套列只为每个商品附加 `need_ids`、中文 `need_names`、`category_text`
和 `has_bundle` 展示元数据。同一 good 属于多个 need 时仍只显示一行并列出全部用途，不生成
替代方案分组，也不得用嵌套 component 行重新累计总量。新增列仍是 selected-cell 冷查询输出，
不进入 catalog hash、PKEC schema 或持久状态。

世界生成页的“生成测试经济数据”默认关闭。显式启用后使用石器中期科技，只在已发现资源能
支撑配方的地块放置 collector，并只在本地上游齐全时放置 industrial；升级族只放置最高可用档。
候选建筑按食品 `1300`、衣着 `4` GOODS_SCALE/人/日检查净产能；食品/衣着直接消费品作为产出
增加容量、作为生产投入扣减容量。削减时只移除重复栋数并保留每种可用建筑至少一栋，仍无法覆盖
一人最低需求的地块不生成聚落。随后按保留的 owner/employee 岗位容量聚合 cohort，初始就业和
库存保持为零。fixture 会在 GDScript population packet 中提前执行 native merchant invariant
同形的“从最大非商人 cohort 转 1 人”步骤，并按 30 日生存金、业主两周期输入金和商人目标库存金配置启动资金；
总人口仍等于建筑岗位人口，native bootstrap 不再需要二次修复商人。它是开发 fixture，不是正式历史人口来源。

## 实测门槛

Windows / Godot 4.6.2 / template_release / 2026-07-11。下表是显式
`market_cycle_days=0` 的自动周期性能档；该模式现为生产默认：

| 档位 | 样本 | avg | p95 | max | runtime memory | ACTIVE 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10k cells / 200k cohort / 100 goods / 16 needs / N=50 | 2500 | 1.883ms | 2.766ms | 3.126ms | 101.0MB | 通过 |
| 100k cells / 10m cohort / 200 goods / 16 needs / N=334 | 668 | 5.542ms | 6.333ms | 9.394ms | 1680.6MB | 通过 |

错峰把 10M p95 从约 89ms 降至约 4ms；惰性会计清零和按需 merchant rebuild 消除了
周期边界 90/30ms 尖峰。代价是可配置的结算延迟与 reference 误差，详见调度文档。
# Native Building / Employment Runtime（PKEC v14 + PKCN v1）

建筑、岗位与生产由 `NativeEconomyRuntime` 内独立的 `BUILDING_GRAPH` 管理，仍与
Market V2 共用冻结周期和原子发布边界，但不进入 `household_market` 热循环。建筑不进入
`MapData`/`HexCell`/DataCore schema；运行时以按 `(cell, building_type,
owner_signature)` 排序的稀疏 POD owner-lot 保存数量，并用 cell CSR 只遍历有建筑地块。

`BuildingProfile` 编译 owner/employee role、建造成本、输入/输出、投入候选 CSR、自然资源交互模式和 postfix
建造条件。人口仍保持唯一 `(cell, signature)` cohort；lane 新增 owner/employee employed
计数。**失业者是一等 cohort**：新增保留 profession `unemployed`（消费走极简 `plan_unemployed`，
仅 survival food），按 ethnicity 分桶生成 `unemployed|<eth>` signature；失业惩罚由 starvation
自动施加（收入 0 + 只吃 survival food → satisfaction 掉 → 自然死上升，无硬编死亡率）。就业为
**跨周期存量**（A1 真实人口迁移）：非商人/非失业的 `profession|eth` cohort 恒有
`owner_employed + employee_employed == population`（无闲置，未被雇佣者立即迁往 `unemployed|eth`）；
`_unemployed_population` = Σ(unemployed cohort population)，是派生量、不进 save/hash（失业 cohort
本身随 population section 存档）。工资 ABI 位于 employee role：`adaptive` 以本地基础生活
成本、岗位 cohort 消费篮子和本地岗位合同工资 EMA 形成生活工资硬下限；`fixed` 仅保留给
显式固定报酬内容。当前跨时代目录用低额 `fixed` 报酬近似奴隶维持、农奴供养、租佃和契约
劳工的食宿/份额，使用 profession stable ID 区分关系；它不提供法律身份、地租倒流、迁徙限制
或 owner-lot 人身绑定。产品出售后，业主现金不足时按 owner 全部 role 义务稳定比例支付；最终
欠薪取消奖金并保留诊断，但不追溯取消本期生产。工资仍按本地同职业实际就业权重分配，不铸币且
保持资金守恒。

普通生产建筑禁止使用 merchant owner。唯一例外是石器期砂金与露天银矿点：无商品投入、保留对应矿工岗位，
必须消耗匹配的金/银矿藏且只产对应金银。市场接受产出时按固定面值增加业主商人资金，并进入
`_explicit_money_mint`、`bullion_money_issued`、金银分项发行额与 closing audit。后期金银矿仍由
industrialist 持有并保留工业投入、矿工和管理岗位。不存在虚空商站铸币分支。

投入边可以是精确 good，也可以声明 category 与最低质量等级。`EconomyCatalog` 将类别展开为按
stable good ID 排列的候选 CSR，并附带 good-level Q16 生产效率。每个输入槽另有
`input_required_q16`：默认 `65536` 保持旧的硬互补行为；`0..65535` 表示软输入，缺货时保留
`1 - required` 的产能底线，库存/现金越接近完整物理需求，产能越线性恢复到满产。native 在冻结国家科技可用的候选
中按 `price / efficiency` 选择最低有效成本；生产期还要求本地正库存。物理消耗为
`ceil(effective_required / efficiency)` 乘以该产能实际需要的输入购买比例；若完整物理需求为正且购买比例为正，scaled 购买量至少为 1，避免硬输入在极低利用率下被截断为“零成本免费生产”。库存、业主现金与 goods audit 仍记录实际物理数量。
这使早期木材等配方可以直接使用打制石器、青铜、金属或精密工具，不再需要商品转换站；每个输入槽仍按建筑时代设置最低品质，因此探索以后不会再选中打制石器，信息/AI 只接受精密工具。石器狩猎营地的工具槽当前设为 `32768`，无工具时仍能低效狩猎，有工具时恢复到完整效率。

`upgrade_family_id/upgrade_tier` 编译为稳定 family 目录与逐建筑 tier。BUILD 检查同族最高已解锁
档位，旧档返回 `building_tier_obsolete_for_construction`；生产仍只检查该建筑原始科技，因此旧
owner-lot 继续生产且不会自动转换。快照发布 family、tier、highest available tier 和当前可建状态。
食物与家庭织布各只有 gathering、pottery、guild、steam 四档，蒸汽后不再扩展。

周期开始先按冻结价格计算每栋建筑的投入替换成本、完整工资义务、预期 producer settlement
收入与目标营业利润率，作为诊断和销售后利润分享依据。计划利用率按可售产出的真实售罄率调整，
耐储商品保留 1/32 探测下限，易腐/周期流商品保留 1/6 下限；严重亏损状态机仍是完全停产的唯一入口。生产者自留只在该业主实际生产的单组分生存食品或寒冷衣物之间重新归一化，不再把最低生存额稀释到其无法生产的理想替代品上。

周期开始时先做**增量就业**（不再全量清零重建）：按本周期计划利用率目标夹紧各建筑
`filled_owner`/`_building_employee_filled`（缩产差额裁员 → 超出目标的在岗人口迁往 `unemployed|eth`），
再让活跃建筑按 `(realized_profit_margin_q16, planned_utilization_q16, group_index)` 稳定序**跨建筑类型**
优先从失业池增量招人（先喂最赚钱；招人跨原职业，失业者可被任意缺人建筑吸收，ethnicity 不变）；
同一 owner signature 被多个建筑组共享时，现有 `filled_owner` 也按该优先级夹到该 cohort 的存活人口，
防止人口减少后各组分别“已填满”但 cohort 无对应在岗人口。household demography 与 structural commit
ACTIVE 自营业建筑的 planned owner demand 始终等于完整物理业主席位，planned utilization 只降低
每栋投入、产量和资源消耗；RECOVERY 才按 probe capacity 缩放业主需求，SUSPENDED/不可用组为零。
`planned_owner_equivalent` 是利用率折算诊断，不是可裁撤岗位，因而 ACTIVE 的 `filled_owner` 高于该值
属于正常状态。业主岗位流动的 `projected_owner_income_per_day` 按
`max(planned owner demand, filled_owner)` 计算人均值；已消费的自留生存物资继续按冻结零售价计作
实物生活收入，但不铸币。
之后、publish 之前另执行一次只裁不招的就业对账，使 committed `filled_owner`、role fill 与 cohort
`owner_employed/employee_employed` 始终一致；新空缺留到下一周期正常招聘，不追溯改变本期生产或工资。
失业池招聘完成后，仍有业主空缺的 ACTIVE 非服务建筑可从同民族、至少有一名业主的 ACTIVE 非服务建筑
吸引一名业主。目标按冻结预期业主日收入降序，来源按该收入升序；只有目标收入严格更高时，才按
`(target_income-source_income)/target_income` 做无状态确定性概率判定。每个目标和来源建筑组每周期
最多参与一次成功流动，来源可失去最后一名业主，但最后一名本地商人不可流出。同职业只重配两个组的
`filled_owner`；跨职业才通过 `move_cohort_population()` 按人口比例携带资金和当期 cohort 账目，
不发生出资、建设或额外现金转移。SUSPENDED、service、不可用建筑与不同民族不参与。
利用率坍缩时失业者获跨周期缓冲、可长期失业，不再每周期从零重摊。商人全程排除（`ensure_merchant_invariant`
保持），其失业/商业萧条为独立后续设计。随后业主按本地价购买输入并生产。每个 owner 从统一
`survival_household` 基础量、冻结人口/环境和民族修正计算无财富/价格弹性的生存量，只对主食、蛋白质、蔬果保留饥饿阈值比例，并按寒冷
暴露保留最低衣物；其他需求和超过最低量的产出直接进入 offer。商人按 `max(feasible demand, actual withdrawal) + export EMA` 与 30 日基线乘商品比例后的有效库存天数计算
库存缺口，以 good-specific `merchant_buy_price_factor_q16`（默认
`62259 / 65536 ≈ 95%`）计价。该配置是硬上限：库存为零或极端短缺也不会把生产者
结算系数推向 100%；短缺、生存品和生产投入只改变数量与预算优先级。期初采购现金
保留 12.5%。Price V4 的成本锚继续用“生产者所需结算价 ÷ 收购系数”反推零售目标，
因此可同时覆盖生产者成本和商人流通毛利。

国内贸易按目的地冻结 `max(0, merchant_cash - existing_order_reserved_cash -
merchant_cash × merchant_procurement_cash_reserve_q16)`。候选裁量、利润裁剪与最终
扣款使用同一余额并逐单递减；资金不足记录现金拒绝，不创建零数量或未充分预留订单。
若 survival food / cold-clothing 出现居民短缺，或生产投入 reserve 大于当前库存，native 会把 `last_shortage_q16` / reserve shortfall 转为 `trade_relief_pressure_q16`，提高本地库存目标和商人采购目标；建设命令因材料库存不足被拒绝时，也会把材料缺口写入 business demand / non-household withdrawal，使后续采购和贸易能看到长期建设短缺。未解锁施工材料直接返回 `building_construction_good_locked`，不会生成采购需求。
无历史出库或本地供给时仍按完整有效天数建立冷启动做市库存，
其余预算按缺口价值和稳定 good/group 顺序分配；未获正常采购的耐储余货按本地零售价 20% 托底发行并入库，`cycle_flow` 余货先低价清算/托底、再在 cell 边界清零。销售后统一分配工资和奖金，居民再用本期收入购买
包括本期新产出在内的库存。留用品直接增加该 owner 的 need filled，不转移资金；未消费余量按
来源 owner-lot 计入 `last_discarded`。建筑采样使用
`max(0, reserve + min(pending_extra_change, 0))` 作为有效可采储量：尚未被资源 pass 消费的负
delta 会阻止跨周期重复超采。每条资源边有 `extract` 或 `capacity` 模式：extract 按产量扣减并
发布负 delta；capacity 只以 `reserve / (building_count × requirement)` 限制产能，不扣减储量。
自然资源 reserve 与 goods 使用相同的定点尺度，但不是同一种经济单位。extract 配方按采集方式、
技术和资源类型使用 `2:1` 至 `25:1` 的总产出/资源投入效率；例如砂金淘洗 `2:1`、露天银矿
`4:1`、蒸汽煤铁矿 `12:1`、现代煤铁矿 `20:1`。多副产品按输出总量计算。原生公式仍分别读取
资源投入量和物资产出量，因此效率分级不增加新状态、调度、API 或存档字段。
农场使用旱作耕地/水田/种植园容量和肥沃土壤生产 crop goods，不再培育 crop resource。
资源边只允许 `local`。海鱼储量由 `coastal_land` habitat 直接生成在与海洋相邻的沿海陆格，
岸上渔场、狩猎营、矿山和农场 capacity 都只检查建筑本格；catalog 和 native 配置同时拒绝非本格
访问模式。该约束不增加运行时状态，且移除了生产热循环的邻格 gather。

世界设置启用测试经济数据时，fixture 先生成资源适配的自给、采集与本地产业 owner-lot，随后
通过 `EconomyFacade.building_job_spec()` 读取 catalog 岗位列并派生 cohort。生成前用
`building_placement_spec()` 的投入/产出数量计算本地净食品和衣着容量。每格目标人口为岗位容量、
食品承载人数、衣着承载人数的最小值，并封顶 `300`；商栈的一个 merchant 岗位也计入人口和生存
容量。重复建筑只削减到该目标，每种已投放类型至少保留一栋；不具备最低承载力的地块不生成人口。
人口结构不再作为建筑生成输入；建筑岗位配置变化会直接改变新地图的职业人口结构。

Inspector 首屏通过 `get_population_cell_summary` 只读取人口聚合值；人口需求、市场、建筑与自然
资源明细由可见标签惰性读取，避免点击成本随全局 goods/building catalog 扩张。完整 snapshot 在
Facade/UI 只读传递，不再为缓存和返回值各做一次递归深拷贝。

公共冷路径 `get_building_cell_snapshot` 返回建筑 owner-lot、岗位实到、周期投入/产出/销售、
资源容量/采收及选中地块的 reserve/pending/effective 三列。PKEC v5 的历史字段
`last_resource_generated` 仍为 byte-layout 兼容保留；当前 crop-capacity 目录不依赖正培育。
食品和气候衣着不足在居民清算后产生确定性死亡，不以前一周期满足度前置削减就业人口。
Inspector 对 capacity 边显示有效容量，对 extract 边显示实际采收。v4 的实际投入成本与实付工资继续用于
利润；v8 另保存 role 合同工资、生活成本、当地均薪、基础工资/奖金、欠薪停产标记和稀疏
LaborMarketStore。利用率按带舍入容差和短缺恢复的售罄率响应；生产完成后仅将超过目标业主利润的 25% 结为奖金。
命令流包含 BUILD/DEMOLISH；v2-v7 均可迁移，缺失字段使用确定性默认值。

10k cells / 10k owner-lot / 30k cohorts、固定 N=5、template_release 的同工作树 A/B 中，
禁用生活成本调用 p95 为 9.098ms，启用完整机制为 9.388ms，净回退约 3.2%；完整机制
`wage_plan_ms=0.34ms`、`labor_signal_ms=0.30ms`、5000 个稀疏 labor edges，
runtime memory 114.6MB（SELECTIVE；TRACE_OFF 为 111.3MB）。该 A/B 用于本次小于 10%
回退门槛，不与较早目录/实现的绝对 p95 混作同基线。

2026-07-12 最终复跑同一固定 N=5 release 场景：SELECTIVE 为 avg/p95/max
`2.414/10.105/10.105ms`、114.6MB；TRACE_OFF 为 `2.222/9.272/9.272ms`、111.3MB。
TRACE_OFF 的 `wage_plan_ms=0.341ms`、`labor_signal_ms=0.326ms`，population/money/goods
error 为 `0/0/0`，无 fallback。

## 建筑资源链性能门槛

Windows / Godot 4.6.2 / template_release / 2026-07-12，历史显式固定 `market_cycle_days=5` 基线：
10k cells、10k 稀疏 owner-lot（煤矿/玉米农场各半）、30k cohorts 共 9 个建筑切片，
avg `2.152ms`、p95/max `8.834ms`、runtime memory `113.3MB`。资源生成/消耗/净变化为
`0 / 224.995M / -224.995M` GOODS_SCALE，population/money/goods error 为 `0/0/0`，
无 fallback。该结果是建筑混合资源边门槛，不代表自动周期的 Market V2 大规模档。

## 分层经济事件追踪（PKEJ v1）

`NativeEconomyRuntime` 同时拥有 committed economy event journal。生产默认
`economy_trace_mode=SELECTIVE`：所有 market、command、结构变化和稀疏建筑组结算生成紧凑
cause summary；只有 `set_economy_trace_filter()` 选中的 cell 才附带 cohort/market 字段的
`before -> after` delta legs。建筑事件沿用 `(cell, building_type, owner_signature)` owner-lot
身份，不创建逐栋建筑 Object。

worker 只把选中 market 的 detail fragment 写进 `MarketResult`，主线程按 market index 稳定
append，并在 append 时增量生成 provisional event ID 与 stream hash；`aggregate_publish` 守恒
通过后只做 O(1) batch commit。失败 epoch 丢弃 staging events，handler 永远看不到未提交变化。

GDScript 通过 `poll_economy_events`/`ack_economy_events` 的独立 consumer cursor 批量读取
PackedArrays。通用 gameplay event bus 每次只接收一个 `ECONOMY_EPOCH_COMMITTED` 通知，
不承载高频 delta。事件不参与核心 economy state hash；另以 `event_stream_hash` 验证
scalar/worker 事件确定性。

玩家人口 Inspector 使用独立的 `set_economy_inspector_trace_cell()` 单地块目标。事件 schema v4
新增 `producer_support_issuance`，把托底发行与普通 `owner_operations` 收入分开。冻结周期中
worker 仅把居民消费与商人居民销售写入局部结果，主线程再与工资、业主经营、产业供货、商人
收购、建设和转移支付资金腿合并；提交时以 cohort 总账补齐 `other`，保证来源合计严格等于
`epoch_income/epoch_expense`。人口快照返回上次提交的 cohort-major 稀疏 cashflow CSR、周期
日期与 available/pending。滚动五相模式只为本日到期地块发布完整 cashflow；未到期日不会用
旧总账对零条本日来源做 `other` 对账，而是继续返回该地块上一次完整分类。它随 PKEJ retention
有界保留，不进入 PKEC、核心 state hash 或全世界 cohort 常驻布局。

2026-07-13 固定 N=5、10k owner-lot release 复核：SELECTIVE + 单 inspector cell 的 building
slice avg/p95/max 为 `2.236/8.884/8.884ms`、runtime 114.6MB、trace 3.4MB；同版本
TRACE_OFF 为 `2.112/8.914/8.914ms`、111.3MB。两者核心 state hash 均为
`3524023550113083945`，population/money/goods error 均为零。

2026-07-12 / Windows / Godot 4.6.2 / template_release 的同版本 A/B：

| 档位 | 模式 | avg | p95 | max | trace memory |
| --- | --- | ---: | ---: | ---: | ---: |
| 10k cells / 200k cohorts / auto N=50 | SELECTIVE | 1.983ms | 2.685ms | 2.914ms | 6.8MB |
| 同档，选中 1 cell detail | SELECTIVE | 2.056ms | 2.769ms | 3.040ms | 6.8MB |
| 100k cells / 10M cohorts / auto N=334 | TRACE_OFF | 4.986ms | 5.598ms | 7.930ms | 0.1MB |
| 同档 | SELECTIVE | 5.111ms | 5.748ms | 9.238ms | 16.9MB |
| 10k owner-lot / fixed N=5，5-epoch soak | TRACE_OFF | 0.841ms | 1.804ms | 2.096ms | 0MB |
| 同档 | SELECTIVE | 0.865ms | 1.826ms | 1.903ms | 16.8MB |

10M SELECTIVE 相对同版本 TRACE_OFF 的 avg/p95 增量约 2.5%/2.7%；固定五日建筑 soak
增量约 2.9%/1.2%。两档核心 state hash 在 trace 模式间不变，journal 均低于 32MB 默认上限。

## 跨时代产业目录与货币发行（2026-07-14）

现代基线由可复现且支持只读 `-Check` 的 `tools/codegen/gen_modern_economy_content.ps1` 生成，
跨时代扩展后全目录为 120 goods、260
building types、33 professions、18 household needs 和 9 consumption plans。31 种注册自然资源均至少被一个
`collector` 引用；`industrial` 只能消费 goods。所有建筑恰好一个 owner job，科技解锁仅以
`technology_tags` 进入 catalog/snapshot；只有 `tech.*` 是可执行条件。runtime 把条件解析为 dense technology IDs，
由 `NativeCountryRuntime` 以每国家 bitset 持久化；经济在周期边界冻结 `cell → country`、国家 generation/hash 与科技 bits，统一过滤物资替代、职业就业、建造与生产。其他标签命名空间只作冷元数据。

生成器以默认商品价格和消费计划计算每个职业的参考生活成本。fixed 与 adaptive role 的目录工资
均不低于该值；产量取“投入与工资达到目标利润率”和“投入与工资支付后业主仍覆盖生活成本”所需
收入的较大值。内容审计复算同一公式，防止低工资使建筑表面盈利但人口持续死亡。

职业目录优先表达劳动关系和长期技能层，而不是为每个时代/单品建立一次性职业：石器生产由
forager/hunter/artisan 自营；青铜和古典使用小规模 apprentice 与 enslaved_laborer；封建和
探索时期加入 serf、tenant_farmer、indentured_laborer、journeyman；蒸汽以后才由
industrial_worker、technician、engineer、manager、researcher 组成多角色企业。该变化只修改
catalog/content，PopulationStore、signature ABI、BUILDING_GRAPH 和 PKEC byte schema 均未改变。

内容生成器以显式生命周期表区分持续产业和有界产业。只有持续产业会自动获得后续时代生产法；
有界产业在其最后一个有宏观意义的时代停止扩展。审计不再要求每个时代达到人为建筑数量下限，
而是要求每时代非空、累计闭包成立、目录不超过复杂度预算，并拒绝未分类的早期单点生产源。
该约束只改变 catalog 内容，不增加 native 热循环分支、状态列或存档字节。

锂、钴、石墨、镍、铂族和铀的独立目录项合并为显示为“战略矿产”的
`rare_earth → rare_earth_ore → rare_earth_metals` 稳定内部链，并新增独立 `nuclear_fuel` 加工。
核电站与同位素反应堆不再直接消费战略矿物材料。对应的旧 DataCore 资源 slots 已删除；
当前 schema 与 30 个注册资源对齐，当前 catalog 和旧 PKEC stable-ID 表不兼容。

`BuildingProfile` 的单个输入槽可在精确 good、category 候选和显式候选 CSR 三种模式中选择。
显式 CSR 携带配方级 Q16 效率并由 `EconomyCatalog` 按 stable good ID 规范化，native 继续使用
既有 InputCandidate 库存满足度、有效价格和 stable ID 决策。建筑查询通过
`group_input_selected_offsets/group_input_selected_good_ids` 返回每槽上次实际采购项；这是有界的
Inspector 诊断 lane，计入 runtime memory，但不进入 state hash 或 PKEC。restore 后保持 `-1`
直到下一次成功生产。PKEC restore 解码每个建筑组时必须按对应 building type 的 input count
重新分配这一 transient span，并在 `end_restore()` 校验 span 边界；缺失或越界必须在恢复阶段
明确失败，不能延迟到后续 `BUILDING_PRODUCTION`。该扩展没有修改权威公式或存档字段。

`gold`/`silver` 的 `monetary_issue_value` 默认分别为 800000/50000 money subunits。市场接收
建筑产出的金银时不扣既有现金，native 将付款计入 `_explicit_money_mint`；金银随后作为普通
库存参与珠宝、电子等生产且不重复发行。report 分别发布 accepted quantity、issued money 和
`bullion_money_issued`。普通产出的正常采购仍受 merchant cash cap，余货则走低价托底发行。merchant 建筑预检只允许单一金/银产出、
严格对应的唯一金/银矿藏、extract 行为且无资源生成；后期矿井可以有雇员和工具输入。

职业消费使用八套结构不同的原型；全部原型都包含主食、蛋白质、蔬果、衣着、居住、家庭用品、
卫生、医疗和家庭能源九项基础需求，其他舒适/奢侈需求按生存、农业、采掘、产业工人、工匠、
技术、商人和业主原型分层。基准数量不再用统一的 food/non-food 常数，而按实际消费频率配置；
各原型再分别应用基础、舒适、奢侈三档比例，财富弹性从主食的低弹性逐步提高到身份消费。
`survival_household` 继续作为自适应工资的生活成本基准。

三个饮食 need 对 UI 统一显示为“食品”，但 native 仍分别保留营养、价格和技术替代权重；野味是
蛋白质替代品。Inspector 从嵌套 CSR 枚举计划内全部组件，以 market 科技位过滤，零分配但已解锁
的替代品仍显示；数量和支出仍只来自 `demand_good_*` 聚合列。`needs_satisfaction` 的权威语义改为
食品总满足与气候衣着满足的较小值。周期开始时仍存活人口先就业和生产；默认 50% 是消费后的
饥饿满足度阈值，不前置削减劳动力。Q32 饥饿死亡率使用既有 residual、birth/death 审计和结构
回收路径。默认职业年出生/自然死亡率为 3.0%/2.5%；出生按生存满足率线性缩放并使用
`seed/sample_day/cell/ethnicity` 无状态 Q32 舍入，不新增额外 PKEC 字段或调度阶段。

建筑基础工资不再预付；生产出售后用 owner 销售后资金统一分配。最终欠薪继续记录在
`wage_suspended`/unpaid 报告中并取消奖金，但该标记不代表下一轮自动停产。

居民直接消费不再使用 railway_equipment、oceanic_vessels 或 scientific_instruments 代理交通/科研
服务。前两项在基础设施/服务经济落地前作为明确的无家庭需求资本品保留；scientific_instruments
仍有精密工具生产下游。允许的跨 need 复用仅为 refined_fuel、computers、beverages 和 fur，
Inspector 会聚合显示。需求/计划变更只改变 catalog hash；旧 hash 的 PKEC 按现有
`save_catalog_scale_or_capacity_mismatch` 路径拒绝，byte schema 与五日默认 cadence 不变。
生成目录遵守 16 needs、每 need 8 variants、每 variant 4 components 的运行时合同；本轮加入
野味后实际最大 variant 数为 5，最大 component 数仍为 2。聚焦处理量以当前 schema 测试输出为准。

`electricity` 是唯一 `cycle_flow` good。`building_production` 内先运行只产出 cycle-flow 的
utility groups并结算 offers，再运行其他 groups；cycle-flow 产出会先按本周期可售量进入同周期低价清算/producer support，随后剩余电力在 cell 生产结束时清零并计入 goods
sink。report 发布 `cycle_flow_produced/consumed/discarded`，跨周期市场库存必须为零；家庭公用
事业结算尚未实现，因此家庭能源替代不包含电力。

软件、数字服务、AI 模型、轨道科研、遥测、卫星、深空探测、轨道回收与聚变燃料链本轮删除，
不再伪装为可交易服务或地表商品。本轮不建立服务经济或轨道市场替代系统。

2026-07-12 template_release Price V3 验证：100-good/200k-cohort auto N=50 为
avg/p95/max `1.883/2.766/3.126ms`、`101.0MB`；200-good/10M-cohort auto N=334 为
`5.542/6.333/9.394ms`、`1680.6MB`。10k cells/10k owner-lots/124 goods、固定 N=5、
SELECTIVE 的 building slices 为 `2.152/8.834/8.834ms`、`113.3MB`，三项审计均为零。
相对改造前同目录基线，三档 p95 分别变化 `-4.1%/-40.1%/-27.3%`，runtime memory
分别变化约 `+0.1/+0.4/-0.4MB`，满足 p95 不回退超过 10%、内存增量不超过 64MB 的门槛。

2026-07-14 产业链简并后的最终 template_release、固定 `N=5`、`TRACE_OFF` 复核：

- Market V2 synthetic 10k cells / 200k cohorts / 100 goods / 16 needs：2500 samples，
  avg/p95/max `1.838/2.982/3.665ms`，4 worker tasks，runtime memory `94.6MB`。
- 实际 181-building catalog 的 10k owner-lot / 30k cohorts：每次 9 building slices，最终二进制三次
  中位 avg/p95/max `1.359/5.945/5.945ms`，三次 p95 范围 `5.733-7.642ms`，观察到的
  all-slice max `11.801ms`，runtime memory `111.9MB`。
  `production_output_discarded=0`、`building_wages_unpaid=0`，population/money/goods error 为 `0/0/0`。

以上是历史显式固定五日 cadence 证据，不与 workload-auto 数据混用。

同日 habitat/geology/crop-capacity 收口后的 `TRACE_OFF` 复核：100 goods / 200k cohorts 为
avg/p95/max `2.290/2.961/3.589ms`、`94.2MB`；200 goods / 10M cohorts 为
`5.372/6.072/8.891ms`、`1663.8MB`。加入 frozen 六邻资源访问后的 10k owner-lot 混合建筑档为
`2.129/8.643/8.643ms`、`110.2MB`，记录 `capacity_checks=10000`、
`capacity_limited=0`、`extract_limited=0`，population/money/goods error 仍为 `0/0/0`。

2026-07-15 need 总量价格弹性与企业售罄率响应加入后的 template_release 复核：同一 synthetic
10k cells / 200k cohorts / 100 goods / 16 needs，auto `N=50`、SELECTIVE 为 2500 samples、
avg/p95/max `2.064/2.919/12.441ms`、`112.8MB`；固定 `N=5`、`TRACE_OFF` 为
`2.185/3.269/3.892ms`、`94.6MB`。相对 2026-07-14 固定五日 TRACE_OFF 的 p95 增幅为 9.6%，
低于 10% 门槛；总量价格幂仍只按 market×need 预计算，不进入 cohort hot loop。
## 2026-07-18 producer viability and procurement calibration

- Owner-operated building plans and output cost anchors include the filled
  owners' frozen-period base living cost. This is a viability/cost signal, not
  a wage transfer and not a new wallet. Realized-loss suspension still uses
  actually paid inputs and employee base wages, so an imputed owner income does
  not create a fake cash loss.
- A producer cohort reserves at most one period of base household cost and at
  most half of its current cash. The reserve constrains physical inputs and
  discretionary profit bonuses. Contracted employee base wages remain senior
  claims and may use the full owner balance; the reserve therefore cannot
  manufacture wage arrears or permanently lock a viable workshop out of its
  next input purchase.
- Merchant bids interpolate from the configured base buy factor toward frozen
  retail price as shortage or the unchanged inventory-target gap grows.
  Procurement budgets are weighted by survival, shortage, and production-input
  urgency, capped by each good's actual target gap value, and repeatedly
  redistributed when a high-priority good reaches that cap. Inventory horizon
  and target quantities are unchanged.
- The mid-Stone-Age hand workshop lots are demand-sized: household weaving uses
  `120 -> 90` goods units/day and knapping uses `100 -> 140` units/day. This
  prevents one five-day cottage batch from overshooting local cloth/tool demand
  by an order of magnitude while preserving physical inputs and owner jobs.
- These fields are derived from existing authority columns. PKEC schema and the
  five-day committed cadence do not change.
## 2026-07-20 PKEC v14 economic repair

PKEC v14 keeps `NativeEconomyRuntime` authoritative and replaces the former
cash-compressed production signal. Each frozen production cycle now records
desired, funded, and unfunded business demand. Desired demand drives the sparse
market signal, price pressure, trade relief, and investment gap; funded demand
alone may buy inputs and produce goods.

Working capital is allocated once per `(cell, owner_signature)` across all
owned building groups. A capped livelihood reserve and the part of base payroll
not covered by frozen expected revenue are protected. Critical survival and
downstream-input groups receive a deterministic first-pass allocation of up to
25 percent of desired cost, followed by score-ordered allocation. No account may
become negative and no money is created by this allocator.

Endogenous investment is reviewed every 10 days and considers every
technology-unlocked building type, including types absent locally. Every catalog
building has an explicit, positive construction recipe; an empty recipe is a
codegen/audit failure rather than a zero-cost investment exception.
Required capital includes construction goods, two market cycles of inputs, one
cycle of base wages, and 30 days of owner livelihood. Every same-ethnicity
cohort with enough cash after retaining its full 30-day livelihood reserve is
eligible; the last local merchant is the only mobility exception. Projected
owner income must exceed current per-capita income. The fixed-point income-gain
ratio is the investment probability, sampled deterministically from
`seed/day/cell/type/signature`. A cross-profession winner moves one person and
the required capital into the building's configured owner profession; an
already matching owner cohort invests without a fabricated mobility transfer.

## 2026-07-26 weighted worker and exact audit update

`NativeEconomyRuntime` remains the sole mutable authority. Building-plan
evaluation, production, and household markets now use deterministic contiguous
weighted ranges capped by `economy_worker_task_cap` (default 6). Plan metrics and
production/market result buffers are task-local; the authority thread waits and
merges by task id, preserving scalar state and event hashes. No new DataCore
slot, bridge packet, PKEC field, or fallback is introduced.

Opening totals reuse the previous exact committed close on ordinary days and
refresh country treasury cash/goods directly from `NativeCountryRuntime`.
`economy_full_audit_verify_interval_days` defaults to 25 simulation days (five
economy epochs) for a periodic complete opening scan. The closing audit and
population/money/goods conservation checks remain complete on every rolling
transaction.
Collector entry is additionally constrained by the current cell-resource
budget: renewables use reserve-responsive safe yield, while non-renewables must
retain the configured deposit runway. Local construction conditions and the
1 percent 30-day bullion issuance cap remain.

Investment catalog traversal now has an exact sparse front end controlled by
`economy_investment_sparse_mode=OFF|PROBE|ACTIVE` (default `ACTIVE`). Only a
cell whose capital review is due refreshes its market's transient active-good
bitset from frozen household/business demand, supply, realized withdrawals,
exports, stock, and the exact merchant inventory target; ordinary household
markets do not pay for a second full goods scan. A catalog-baked
output-good-to-building CSR expands those goods to candidate types. Existing and pending local types are always retained,
and their construction inputs close the candidate set recursively, so repair,
growth, and same-review construction-shortage feedback cannot disappear.
`PROBE` evaluates the full country catalog while measuring the subset. `ACTIVE`
skips only types outside the conservative closure; inspector diagnostics and
every `economy_full_audit_verify_interval_days` boundary still perform a full
scan. If a full scan ever finds a viable omitted type, the runtime increments
`investment_sparse_mismatches` and disables sparse filtering for the rest of
the session. The reverse CSR, bitsets, and stamps are derived caches and are
excluded from PKEC, state hash, and event hash.

The default merchant inventory horizon is 60 days. Per-good target ratios still
compile to one dense Q16 days column, so ordinary goods target 60 days,
survival goods 90 days, important goods 75 days, and luxury goods about 40 days.
This changes configuration only: market cadence, save layout, and ownership do
not change.

The 20 percent producer-support price remains a cold-start fallback. Issuance is
capped per cell at 5 percent of opening money per 30 days. All support and
bullion issues remain explicit mint audit entries.

## 2026-07-22 construction closure and investment v6

The generated catalog assigns all 261 buildings a positive construction bill.
Recipes scale with owner plus employee slots, remove every self-output, and give
construction-material backbone producers only earlier topological materials.
The content audit closes construction goods and recurring production inputs
together for ranks 0 through 10, starting from gathering/merchant/timber/stone
roots and one-time `logs=1000`, `gathered_plants=250`, `flint=500` bridge stock.
Unreachable components are reported as construction dependency SCCs.

`endogenous_owner_portfolio_v8` selects one deterministic marginal output per
candidate. Driver strength is the maximum of raw persistent shortage pressure
and single-building utilization, with pressure, utilization, and stable good ID
as tie breakers. A positive marginal deficit and utilization allow viability
evaluation; no minimum shortage/utilization, sell-through, or discard ratio
pre-approves or vetoes profit. Sell-through counts merchant cash purchases only:
owner retention, producer support, and bullion issuance do not count. Projected
revenue is summed per output after applying that output's observed merchant
absorption or persistent deficit, so a scarce primary output can drive entry
without assuming that every by-product sells at its quoted price.

Monetary-issue outputs are the explicit exception to ordinary market absorption.
For a building whose outputs all have a positive `monetary_issue_value`, household
and business demand EMA does not throttle planned utilization because production
settlement sends the full sellable batch to the mint. Investment keeps
`merchant_sold` limited to cash-funded merchant procurement for diagnostics, but
treats mint settlement as 100% economic sell-through, seeds a first entrant with
one building of mint-backed utilization, and values projected revenue at the
catalog issue value. The existing 30-day issuance-share cap, local construction
conditions, construction materials, wages, owner livelihood, and capital checks
still apply. Collector candidates must also fit the renewable safe-yield or
non-renewable deposit-life budget after installed, pending, and same-review
portfolio extraction are counted.

The three sparse current-cycle producer lanes and all driver diagnostics are
transient. They do not enter PKEC v20 or the state hash. CSV v19 adds the driver
good, pressure, utilization, sellable, merchant-sold, sell-through, and discard
columns.

## PKEC v20 rolling settlement (current)

The production runtime no longer waits for a global epoch. Stable cell phase is
`cell_id % 5`; simulation day `d` commits phase `d % 5` with `dt=5`. Bounded
native continuation calls run plan, employment, production, household clearing,
price/EMA, investment, audit, and publish for the due workset. Each call consumes
up to eight deterministic chunks and may fuse cheap phase boundaries while its
0.8 ms normal / 1.8 ms high-speed budget remains. While the due bucket remains
in flight, the same-day barrier drives consecutive bounded continuations inside
the current real-frame `sim_frame_budget_ms` time box. It stops before starting
another range once the budget is consumed, or after a defensive maximum of 64
continuations. Completed cells publish together at the final boundary, with
`max_state_age_days<=4` and `deferred_cells=0`.

Trade arrivals, refunds, escrow release, and invalid-order handling are daily
transactions. ETA is `departure_day + ceil(route_cost / daily_speed)` and is not
aligned to a market boundary. Incremental route planning may continue across
days, but it cannot defer the due local phase.

PKEC v20 persists per-cell settlement dates/generations, dirty generations,
building recovery pending state/cooldown, BuildingIdentityStore, and the Economy
Modifier domain. Restore accepts v18/v19 by initializing missing Modifier state
to empty (and v18 recovery fields to `NONE/0`); v2-v17 are rejected as legacy. References to
PKEC v14 above describe historical rolling migration, not the current reader.

Accuracy policy is configured independently as
`EXACT|BALANCED|FAST|CUSTOM` and rollout as `OFF|PROBE|ACTIVE`. The production
default is `BALANCED+ACTIVE`: non-survival variant families use the certified
anytime frontier, while deterministic 1% exact probes validate its demand and
spending allocation. `ACTIVE` always keeps the highest-scoring exact candidate,
begins with deterministic Top-K, and adds candidates until omitted score mass
is below the configured regret certificate. Food/clothing survival families
are never pruned. An invalid certificate, a failed exact probe, or an active
cooldown takes the exact local path. `OFF` and `PROBE` remain exact
rollback/baseline modes. Reports use
`rolling_cell_settlement_v17_anytime` and expose decisions, probes, frontier
size/pruning, certified regret, failures, and fallbacks. These frontiers are
derived scratch and are not persisted.

While the unresolved large-world household worker race is isolated,
`BALANCED+ACTIVE` worlds above 4096 cells keep household market settlement
scalar; building plan, production, and audit workers remain enabled. Report
field `approximation_large_world_scalar_guard=true` makes this containment
visible. The 2400-cell certified performance scene continues to use household
workers.

The rolling hot path also keeps a non-authoritative per-cell demand-basis cache.
Building owner-retention and household clearing share the same frozen prices,
technology, and environment, so fixed-point elasticity/power terms are computed
once per due cell. Due building cells precompute disjoint cache slices in stable
worker ranges; saturation counts are reduced in cell order. The cache is excluded
from save and state hash and is rebuilt after restore. It adds about 18.2 MiB in
the 2400-cell building benchmark, within the 64 MiB rollout ceiling.

Building planning aggregates survival utilization floors in linear cell-local
passes over owner signatures; it no longer rescans all later groups for every
owner. Production market-signal observation uses cell-local CSR scratch lanes
instead of catalog-wide good arrays. Endogenous investment runs as bounded
rolling-phase cell continuations backed by epoch-transient `(cell,type)` pending
and existing indexes plus a `(cell,resource)` harvest index. Sponsor, population,
cash, material, and construction mutations remain in stable cell order.

Building production now partitions the due-cell range through
`parallel_for_range` when workers are enabled, the range and group counts clear
the configured threshold, `WorkerThreadPool` is available, and the current
identity mapping `cell_to_market[cell] == cell` proves disjoint market ownership.
Each worker mutates only its cell-local population, building, resource-delta,
market, and sparse-signal lanes. Non-local diagnostics, retained output, trace
events, and cashflow entries are accumulated in one `ProductionResult` per cell
and merged on the native main thread in original cursor order. The scalar path
uses the same result-and-merge contract, so worker count does not change state or
event ordering. Reports expose `building_production_worker_tasks` and
`building_production_merge_ms`; merge time is already included in
`building_production_ms`. This changes neither PKEC v15 bytes nor state-hash,
DataCore, bridge, stage, cadence, or continuation inputs.

## 2026-07-20 economy remediation

`NativeEconomyRuntime` remains the sole mutable authority and the default
five-day rolling settlement is unchanged. Employment report totals now use a
per-cell epoch replacement cache, so non-due construction or population
reconciliation cannot create negative unemployment by subtracting live state
that was never counted in the current epoch.

Investment V8 aggregates all owner lots of the same `(cell,type)`, compares
demand with actual offered-supply EMA, caps entry utilization by input coverage,
includes owner livelihood in operating cost, uses markup over cost for the target
margin, and uses recent sell-through only to estimate cash absorption. Owner vacancies are left exclusively to building
employment; they never transfer investment capital or count as candidates.
Rejection codes are: `0` none, `1` pending construction,
`2` suspended capacity, `3` owner vacancy, `4` legacy installed-capacity
diagnostic (no longer emitted by Investment V8),
`5` owner livelihood, `6` legacy sell-through, `7` legacy discard, `8` input chain, `9` target
margin, `10` payback, `11` sponsor capital, `12` materials, `13` resource, and
`14` deterministic probability skip. Codes `6` and `7` remain reserved for
diagnostic/schema compatibility but the current scan does not emit them. Code
`15` means there is no positive marginal output opportunity; it no longer means
that a 12.5% shortage or 65% utilization threshold was missed. The summary report and CSV expose
`building_investment_probability_skips`; `building_owner_mobility` now counts
only profession changes attached to a construction start.
CSV v14 historically added
`building_owner_job_reallocations`, `building_owner_job_profession_changes`,
`building_owner_job_probability_skips`, and building-row
`projected_owner_income_per_day`. CSV v16 additionally publishes aggregate debt,
recovery, in-kind income, trade episode, generation, and arbitration diagnostics.
Suspended groups retain one owner only when no active non-service owner vacancy
exists. Otherwise active-first employment moves that owner through the ordinary
unemployed-pool transition. They retain no employee demand or production intent.

Trade diagnostics distinguish the current unresolved deadline count from
`trade_response_deadline_misses_cumulative`, which increments once per shortage
episode. Selected-cell market snapshots and CSV expose last attempt day, last
rejection reason, and whether the signal is currently over deadline. Diagnostic
reason codes are `0` none, `1` no spread, `2` margin, `3` route, `4` source
stock, `5` capacity, `6` destination cash, `7` order cap, and `8` dispatched.
The current count and maximum age are recomputed from every live signal clock at
the committed boundary; planner-slice resets cannot hide unresolved signals.
Bounded signal collection rotates its deterministic scan origin by simulation day,
and destination ranking serves never-attempted signals before rejected or already
dispatched signals. Destinations with no matching source receive reason `4`
directly at scan completion. This prevents fixed cell/good ordering and the
per-country/good target cap from starving the same settlements forever. These
clocks and scan-order diagnostics are derived state and remain outside PKEC and
state hash.

## CSV v12 livelihood and response diagnostics

CSV v12 separates the merchant opening-cash ceiling from real procurement opportunity.
`merchant_procurement_opportunity` is the priced inventory gap, `allocated` is the
cash assigned to that opportunity, and `unspent_allocated` is assigned cash that did
not settle. Producer-retained goods consumed by their owner cohort are valued at the
committed local retail price and exposed as `epoch_in_kind_income`, with cash-only and
combined livelihood coverage. This diagnostic lane resets per epoch, follows
proportional cohort migration, and remains outside PKEC v15 and state hash.

Current overdue trade signals are bucketed by last rejection reason. The buckets sum
to `trade_response_deadline_misses` and distinguish no attempt, no spread, margin,
route, source stock, capacity, destination cash, and order-cap failures. They are live
diagnostics, not cumulative authoritative state.

High output discard accelerates the existing utilization response when no active
shortage recovery is required. At 25% discard the response is at least 0.75; at 50%
it is immediate. A real shortage recovery signal still has priority, and the
survival/probe floor remains authoritative, so this changes neither the five-day
cadence nor suspension authority.

## 2026-07-21 livelihood, mobility, and investment correction

Subsistence production now has a separate `survival_production_target_q16`, defaulting
to 65536. Hunting plans food and cold-weather clothing retention toward healthy
satisfaction; the 32768 starvation threshold remains only the mortality/work threshold.
Consumed owner-retained output receives a frozen retail-value livelihood credit at its
source building. The credit changes realized profitability only: it creates no cash,
cashflow leg, mint, or money-audit delta. Selected-cell building snapshots expose
`owner_livelihood_in_kind_credit` as derived epoch diagnostics.

Household clearing is the single protection point for input working capital. Production
does not reserve owner livelihood a second time, but still protects the uncovered wage
commitment. A suspended group keeps its recovery owner only when no active non-service
owner vacancy exists; otherwise active-first employment releases and rehires that person
through the existing unemployed pool.

Investment V5 derives entry utilization from `demand - offered_supply_ema`, never from
installed count times recipe output. Each input edge then caps entry utilization by its
soft-required share and actual one-period coverage from unreserved stock plus offered
supply EMA. Zero coverage on a fully required input reports `INPUT_CHAIN`. These are
formula and derived-diagnostic changes only; PKEC v15, cadence, authority, and state hash
Candidate viability also reserves survival-food/clothing output up to the prospective owners'
daily livelihood cost. That quantity is removed from merchant-sellable output and valued at the
frozen retail price only as in-kind livelihood coverage; remaining output alone uses merchant
absorption. The projection creates neither goods nor cash and changes no conservation ledger.
layout are unchanged.

## 2026-07-22 production input quote coherence

Production settlement now quotes the complete input bundle before mutating market stock.
If multiple input slots select the same good, their physical quantities are aggregated
against the frozen stock, matching the production-input reservation rule. The final
candidate IDs and quantities are frozen and reused for stock withdrawal and cash
settlement, so working-capital allocation, executable utilization, and actual input cost
cannot drift because a later slot reselects a substitute after an earlier withdrawal.
Each group also settles against its own allocated owner-capital share before using its
approved merchant-credit share. A recovery group no longer consumes owner cash allocated
to sibling groups merely because that cash is visible in the shared owner cohort account.
At withdrawal time the approved credit is intersected with current local merchant cash;
if liquidity has changed since the frozen recovery plan, utilization is reduced before
any stock mutation. Delinquent groups receive no merchant-credit working-capital grant.
Internal quote/credit invariant failures now include cell, group, type, and financing
values in the fatal reason. This changes no PKEC field, scheduler stage, or authority
boundary.

## 2026-07-21 Price V3 dynamic range correction

Price inventory pressure now uses at most one committed settlement period. The full
good-specific merchant inventory horizon remains authoritative for procurement and
trade stock planning, but no longer makes a flow-balanced good look maximally scarce to
the price integrator. Selected-cell market snapshots expose `price_inventory_target`
beside `merchant_inventory_target` so the two derived horizons can be audited directly.

Catalog `min_price` and `max_price` are legacy reference values rather than normal
market controls. Settlement prices, trade quotes, cost anchors, bootstrap packets, and
PKEC restore validation use only the emergency numeric interval `[1, INT32_MAX]`.
Configured per-day rise/fall limits still bound volatility, and the observed production
cost anchor remains a rate-limited dynamic soft floor. Trade relief is derived from
shortage, unfunded business demand, and production-input reserve gaps; touching a legacy
catalog maximum is no longer a relief signal. PKEC v15 and authoritative state layout
are unchanged.

## 2026-07-22 Price V4 anchored additive pricing and investment feedback

Price V4 keeps uncapped economic prices with directional adjustment references. Frozen
market pressure is clamped by the per-good daily rise/fall rate. Positive pressure is
multiplied by `max(default_price, cost_anchor_price)`, so repeated equal shortages produce
linear reference-value increments instead of exponential increments. Negative pressure is
multiplied by the current market price, so a high production-cost anchor cannot amplify a
glut-driven markdown into an immediate price collapse. The only remaining bounds are the
fixed-point numeric guards. Fully idle goods use a separate bounded mean-reversion step
toward `default_price`; legacy goods profiles receive an effective minimum inactive-reversion
weight of 8192 Q16.

The severe-loss lifecycle consumes the authoritative realized margin directly. That margin's
denominator includes inputs, base wages, and owner livelihood minus retained-goods livelihood
credit. It is not gated by `last_operating_cost`, which excludes owner livelihood; therefore
owner-only workshops enter the same suspension, recovery, and liquidation path as employers.
For an owner-only self-employment group, positive realized business surplus
`cash revenue + retained-goods livelihood value - inputs` prevents severe-loss accumulation even
when it does not cover the owner's full livelihood basket. The remaining livelihood deficit affects
household coverage and demography; it does not suspend a still-productive livelihood and release all
owners. Employer groups retain the full livelihood-and-payroll lifecycle rule.

Endogenous investment evaluates every technology-unlocked building type without a kind-based
allowlist. Collectors use the same market-signal, local-resource, construction-material, viability,
payback, and sponsor-capital gates as industrial buildings. Services without a marketable output
naturally fail the market-signal gate until their content provides an investable demand signal. Every generated
and curated `BuildingProfile` carries an explicit construction bill selected by technology era,
scaled by owner and employee slots, and filtered to avoid self-output bootstrap cycles; the catalog
rejects any profile that omits construction goods. Output demand combines flow deficit with the persistent gap between current
stock and `merchant_inventory_target`; a type is rejected with reason 15 only when both
shortage and projected utilization are below their configured thresholds.

The inspector-selected cell owns a bounded transient candidate table containing every
evaluated unlocked type, including types with no installed group. Rejection reason 17 remains
reserved for snapshot compatibility but is no longer emitted by the general type scan. The table reports rejection,
shortage, utilization, score, payback, required capital, and projected daily profit through
`get_building_cell_snapshot`. CSV v19 appends candidate-only building rows (`group_index=-1`,
`investment_candidate=1`) with the same fields. This table is excluded from PKEC and the
authoritative state hash.

## 2026-07-22 blocked-producer lifecycle correction

Service buildings are outside the producer profit lifecycle; an old suspended service group
is normalized back to `ACTIVE`. For production buildings, only an actually settled severe
loss advances the bounded suspension counter. An owner-occupied cycle with no input, output,
extraction, or generation is a recoverable execution blockage and remains active/idle.
`SUSPENDED_LOSS` always releases every owner to the unemployment pool while preserving
installed capacity.

A suspended producer publishes only a small unfunded upstream probe (1/6 for survival or
cycle-flow output, otherwise 1/32). It neither withdraws stock nor reserves labor or cash.
Permanent-liquidation reviews advance only when the probe inputs, natural resources, and
financing are currently executable but the counterfactual margin still misses the restart
threshold. A supply, resource, or financing blockage resets failed liquidation reviews, so
scarcity pauses the business without destroying it. These probe and eligibility lanes are
epoch-transient and do not change PKEC v19 or the authoritative hash.

An approved `RECOVERY_PROBE` counts as successful only when the group actually executes at
least one input, output, extraction, or generation leg and also passes its cash/economic
checks. A zero-work probe is a failure, publishes `pending=SUSPENDED_LOSS`, and commits that
state only at the next due-cell boundary before the two-cycle retry cooldown.

## 2026-07-23 initial renewable configuration and test-fixture population

Safe yield is authoritative for runtime renewable `extract` edges. At each frozen
cell epoch, all local extractors share a transient budget after retaining
`resource_min_reserve_q16` of that cell's frozen stock. The catalog ecology
capacity remains only the growth-biomass ceiling because it is not a local
climate-adjusted carrying capacity; `capacity` edges continue to read standing stock.
The budget is derived state, is not serialized or hashed, and extraction still
publishes through the existing negative-delta and exact-audit contract.

Endogenous investment counts installed, pending, and same-review portfolio
extraction before approving another collector. Renewable candidates must fit the
daily safe yield; non-renewables must fit `reserve / resource_min_horizon_days`.
Setting `resource_safe_harvest_q16=0` explicitly disables these gates for isolated
fixtures and compatibility tests.

Resource CSV rows keep the existing schema. `safe_yield` is now the local,
reserve-responsive daily value rather than capacity-only potential. For a renewable,
`projected_life_days` estimates days until the reserve floor under installed peak
extraction above safe yield; `-1` means installed extraction does not exceed safe
yield. Non-renewables retain the reserve divided by installed daily extraction.

The optional resource-tiered economy bootstrap uses the same reserve floor and
daily yield to cap renewable building counts at peak utilization. It uses a
3650-day runway only for non-renewables.
The capacity-balanced base owner-lots scale with population as an employment
floor; a physical resource cap is the only reason an extractor may fall below
that proportional count. After all building and merchant jobs are known,
generated population is limited to `jobs / 0.95`; only the employment-target
margin becomes initially unemployed. The explicit uniform stress scales remain
deliberately synthetic.
These changes add report fields only and do not change runtime authority, PKEC
v16, the scheduler graph, or the authoritative hash.

## 2026-07-26 transient indexes and stable bulk signal merge

The sparse market-signal CSR remains authoritative and ascending by
`(cell, good)`. Worlds with at most four million `cell_count * good_count`
entries additionally build a transient dense `int32` lookup. Larger worlds keep
the existing CSR binary search. The dense table, pending-construction cell CSR,
market result scratch, trade-clock merge scratch, and investment signal overflow
are all rebuildable caches excluded from PKEC v19 and the state hash.

Investment does not pre-create construction signals. Only a material shortage
that reached the existing authoritative gate appends an overflow entry. The
entry is immediately visible to later investment evaluation through the dense
lookup, then all actually-created entries are stably merged into the aligned CSR
lanes before aggregate publish. This preserves the reference creation set,
`(cell, good)` order, saturation order, and final hash while avoiding repeated
middle insertion into every aligned vector.

Household result buffers retain nested vector capacity across slices. Trade
response clocks are extended with one sorted merge per market batch instead of
one aligned-vector insertion per `(market, good)`. Both changes retain market
evaluation and commit order; trade clocks remain diagnostic-only. Report fields
split worker, aggregate merge, trade-clock merge, signal insertion/flush,
allocation growth, epoch preflight, and epoch prepare costs. `EconomyDailySystem`
exports the bounded subset as fresh `bd_economy_*` performance CSV columns.

Production uses the same transient-capacity rule: a runtime-owned
`ProductionResult` scratch lane is reset and reused for each due-cell range
instead of reconstructing nested vectors for every continuation. Report fields
`production_result_allocation_growth_count/bytes` expose residual capacity
growth; a warmed steady state should report zero. Building plan and household
post-building passes use deterministic stage-local batching (auto is twice the
normal building cell/group range), while investment/finalize default to 96/128
cells. Profile overrides change only range boundaries and never stable
evaluation or commit order.

The full report also retains one `last_completed_*` snapshot captured after the
publish COMMIT slice. It preserves completed-epoch worker counts, stage totals,
allocation growth, and structure-rebuild diagnostics across the next
`clear_epoch_metrics()`. The snapshot is recorder-only transient state, excluded
from PKEC v19 and the authoritative hash.

## 2026-07-27 incremental audit and review-cell scheduling

Closing audit modes are `FULL`, `PROBE`, and `INCREMENTAL`; the production
default is `INCREMENTAL` after the fixed-seed 200-day daily dual-audit gate
completed with zero mismatch. Incremental totals are computed from opening totals plus
the real delta of generation-stamped population/funds and market-good lanes
captured at their first mutation. Due household/production worksets are
pre-registered on the main thread before worker dispatch, while trade, command,
and structural mutations touch their lanes at the native mutation site. The
shadow, stamps, touched lists, mismatch ledger/lane, and counters are transient
and excluded from PKEC v19 and both hashes. Bootstrap/restore rebuild the shadow;
commit advances only touched lanes. The first day, restore boundary, anomaly,
and every 25th day still run a complete verification; mismatch blocks publish
and disables INCREMENTAL for the session. `PROBE` and `FULL` remain explicit
validation and rollback modes.

`building_commit.review_prepare` now builds one ascending list containing only
the current rolling phase's populated capital-review cells. Investment finance
initialization, pending/existing/resource aggregation, and candidate evaluation
consume that list, and the continuation cursor is an ordinal into it. Reports
publish `investment_scheduled_review_cells` and
`investment_review_cells`; completed epochs require equality. Candidate
evaluation is still scalar. After ready construction is committed,
`building_commit.investment_prepare` now performs the transient finance and
pending/existing/resource aggregation as its own cooperative phase; the following
`investment` phase evaluates and commits bounded review-cell ranges. Both keys are
always present in `building_commit_breakdown_ms/work`. The planned `>=64` read-only worker result plus
stable main-thread revalidation/commit split is not yet production behavior.

## CSV writer backpressure (current)

When both recorder batches are `READY/WRITING`, committed capture now waits for
the worker to free one instead of stopping with `queue_full`; no committed epoch
is skipped. Status adds `backpressure_wait_count` and
`backpressure_wait_ms_total`. Row-limit and real write/flush failures remain
terminal and atomic at epoch boundaries. This changes only debug file-I/O
pacing, not native economy authority, PKEC, state hash, CSV columns, or cadence.
> PKEC v21 新增 `government_research_procurement` 阶段、科技值采购累计与存档字段。采购发生在
> 私人购买后、国内贸易前；详细契约见[科技树、科技值与科研经济运行时](./technology-tree-runtime.md)。
