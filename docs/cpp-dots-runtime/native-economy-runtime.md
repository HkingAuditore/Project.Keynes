# 原生阶层与本地市场运行时（Market V2 / Price V3）

实现入口为 `gdext/src/economy_runtime.{h,cpp}` 与
`gdext/src/world_ext_economy.cpp`。`DCWorldExt` 组合持有独立
`NativeEconomyRuntime`；动态人口和商品状态不进入 DataCore `_slots`，也不回填
`MapData.goods_*`。

> 2026-07-11 状态：冻结周期错峰版默认 `market_runtime_mode=ACTIVE`、结算周期 5 日。功能、守恒、
> worker/scalar 确定性、移动和 10M cohort 性能门槛均已通过。

## 权威边界

| 数据/行为 | 权威 | 契约 |
| --- | --- | --- |
| cohort、handle、人口、资金、收入/支出、满足度 | C++ `PopulationStore` | GDScript 无逐 cohort setter。 |
| 本地库存、价格、居民需求 EMA、短缺率 | C++ `MarketStore` | 无 per-cell goods component，无匿名市场现金。 |
| 企业可行需求/供给 EMA、实际出库 EMA、成本锚 | C++ 稀疏 `MarketSignalStore` | 仅保存建筑实际引用的 `(cell, good)` 边；实际出库用于商人库存目标。 |
| 国内路线、稀疏贸易信号、订单、货物/现金托管、进出口 EMA | C++ `Trade*Store` | 同一冻结国家内预算化规划；PKEC v12 保存订单/托管/EMA。 |
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
- 实际利润率按 `(销售收入 - 输入成本 - 应付基础工资) / max(经营成本, MONEY_SCALE)` 计算。连续三周期不高于 -25% 后进入 `SUSPENDED_LOSS`；停产期间岗位、采购、产出和企业需求全为零。反事实利润连续两周期达到 +10%，且业主可支付一栋一周期输入和基础工资后恢复。
- 商人库存目标使用实际出库 EMA、出口 EMA、目录目标天数和至多一周期短缺恢复量；无历史时只建立一日当前可售产出的冷启动库存。采购开始冻结现金，只允许使用 75%，再按 `库存缺口 × 收购价` 和稳定 good/group 顺序分配预算。
- ACTIVE owner-lot 在家庭清算前按已到岗业主份额、计划利用率和冻结单位投入成本保留下周期营运资金；该资金仍在 owner cohort 账户内，但不会被本期居民订单花掉。报告发布 `owner_working_capital_reserved`。
- 食物生产者按三类食品总需求的饥饿阈值留存产出；精确消费 variant 之后的剩余自产食物可作为跨主食/蛋白质/蔬果的紧急热量，保证狩猎、捕鱼等单一食物生产者具备真实自给能力。
- C++ 按建筑数、周期天数和计划利用率确定性重建稀疏生产投入硬预留。商人目标库存至少覆盖预留；居民与国内贸易只能消费/导出 `stock - reserve`。`production_input_reserved`、`production_input_reserve_shortfall` 及 selected-cell/CSV v5 逐商品列用于诊断。缓存不进入 PKEC v12，可从建筑和市场信号状态重建。
- 正常商人现金/配额无法购买的可储存余货不再丢弃：全部进入商人所有库存，生产者获得冻结本地零售价 20% 的显式发行货币。`production_output_supported` 与 `producer_support_money_issued` 分开报告，货币审计把后者计入 `_explicit_money_mint`；cycle-flow 余量仍丢弃。托底后库存高于正常目标会压低下一周期利用率。
- 生成测试经济不再使用职业固定人均资金：每个 cohort 获得按当前气候、族群和默认价格计算的 30 日 `survival_household` 生存金；业主追加两周期最低有效输入成本；商人追加本地产出目标库存资金。
- PKEC v12 保存并哈希企业状态/连续数/采购意图容量/实际利润率和实际出库 EMA。兼容参数一致的 v11 ACTIVE 可迁移；ACTIVE 配置明确拒绝 v11 PROBE 和 v10。

## 2026-07-15 价格弹性、成本底线与生态修正

- 消费目录新增 need 总量价格弹性和刚需下限。variant 分数仍负责替代选择；总量因子按 market×need 预计算。主食与衣着保留正下限但仍随价格和财富缩量，蛋白质及非刚需可在全体替代品过贵时接近零。
- 低于目标库存且仍有需求时，生产成本锚成为受单日涨幅上限约束的零售价格底线；库存堆积时不启用硬底线。企业同时按上一周期售罄率缩放下一周期计划利用率，但忽略不超过 1% 的舍入丢弃，并在家庭可用库存不超过 1 且短缺率至少 12.5% 时主动恢复。耐储商品保留 1/32 探测下限，易腐/周期流商品保留 1/6 下限。
- 全建筑目录改用默认生活成本和 80% 保守售出率校准：每个 employee role 的 fixed/adaptive 参考工资至少覆盖其职业生活篮子；按默认商人收购价折算后的可售收入同时覆盖投入、工资、目标营业利润和业主生活成本。手工多副产品按原比例整体缩放。石器狩猎营地为 `3200/800/320` 野味/生皮/毛皮、`5` 石器投入和 `715` 野生动物采收；采集营地为 `5600` 采集植物，沿岸渔场为 `3600` 鱼，家庭织造棚保持 `889` 布匹。
- `audit_economy_content.ps1` 遍历 259 个建筑并检查 80% 售出率盈利、role 工资、生产原料成本不超过商人收购收入的 60%、工具维护不超过 `100 GOODS_SCALE/岗位/日`、工业总投入/总产出不超过 `3:1`，以及 `2:1` 至 `25:1` extract 效率；蒸汽煤铁矿固定复核约 `12:1`。这是 catalog/content 校准，会改变 building catalog hash，但不改变 PKEC 字节布局。
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

household market 在建筑生产、产品出售和收入分配后计算食品/衣着生存满足，并执行确定性缺乏
生存资料死亡；它自身不执行出生、迁移、就业、工资、税收或生产。国内贸易在同一经济
边界的 `trade_settle` / `trade_dispatch` 阶段运行：到货先进入目的库存，发运先移除源库存并
托管目的商人现金；随后 household market 只使用剩余/已到货状态。人口命令仍是底层结构 ABI，
居民清算不改变人口。完整契约见 [Domestic Trade Runtime](./domestic-trade-runtime.md)。

## 并行与确定性

slice 按连续 market range 切分；每个 worker 只写自身市场行及其地块 cohort。worker
结果先写 `MarketResult`，主线程再按 market 索引归并指标。定点乘除使用 128 位中间
值与饱和计数；短缺、bundle 和商人收入都使用稳定前缀商，无逐单位余数循环。
focused test 必须验证 worker/scalar state hash 完全相同。

## 公共 API

`configure_economy`、`bootstrap_economy`、`submit_economy_commands`、
`economy_should_run`、`run_economy_slice`、`get_economy_report`、人口/市场 cell
snapshot、reset、分块 save/restore、固定数学 probe 与 state hash。跨边界写入均为平行
PackedArrays；UI 只查询选中地块。

贸易另提供 `capture_economy_trade_topology()` 粗粒度地图输入和分页
`get_trade_orders_for_cell(cell, offset, limit)` 冷查询；禁止跨桥返回全局路线/订单矩阵。

调试录制控制面另提供 `start_economy_csv_recording(config)`、
`request_stop_economy_csv_recording()` 和 `get_economy_csv_recording_status()`。它们管理独立的
`EconomyCsvRecorder`，只在成功 committed publish 且资源 delta 已回写后抓取 CSV v5 POD
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
`market_cycle_days=0` 的自动周期性能档，不代表默认 5 日档：

| 档位 | 样本 | avg | p95 | max | runtime memory | ACTIVE 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10k cells / 200k cohort / 100 goods / 16 needs / N=50 | 2500 | 1.883ms | 2.766ms | 3.126ms | 101.0MB | 通过 |
| 100k cells / 10m cohort / 200 goods / 16 needs / N=334 | 668 | 5.542ms | 6.333ms | 9.394ms | 1680.6MB | 通过 |

错峰把 10M p95 从约 89ms 降至约 4ms；惰性会计清零和按需 merchant rebuild 消除了
周期边界 90/30ms 尖峰。代价是可配置的结算延迟与 reference 误差，详见调度文档。
# Native Building / Employment Runtime（PKEC v12 + PKCN v1）

建筑、岗位与生产由 `NativeEconomyRuntime` 内独立的 `BUILDING_GRAPH` 管理，仍与
Market V2 共用冻结周期和原子发布边界，但不进入 `household_market` 热循环。建筑不进入
`MapData`/`HexCell`/DataCore schema；运行时以按 `(cell, building_type,
owner_signature)` 排序的稀疏 POD owner-lot 保存数量，并用 cell CSR 只遍历有建筑地块。

`BuildingProfile` 编译 owner/employee role、建造成本、输入/输出、投入候选 CSR、自然资源交互模式和 postfix
建造条件。人口仍保持唯一 `(cell, signature)` cohort；lane 新增 owner/employee employed
计数，失业为 population 减两者。工资 ABI 位于 employee role：`adaptive` 以本地基础生活
成本、岗位 cohort 消费篮子和本地岗位合同工资 EMA 形成生活工资硬下限；`fixed` 仅保留给
显式固定报酬内容。当前跨时代目录用低额 `fixed` 报酬近似奴隶维持、农奴供养、租佃和契约
劳工的食宿/份额，使用 profession stable ID 区分关系；它不提供法律身份、地租倒流、迁徙限制
或 owner-lot 人身绑定。产品出售后，业主现金不足时按 owner 全部 role 义务稳定比例支付；最终
欠薪取消奖金并保留诊断，但不追溯取消本期生产。工资仍按本地同职业实际就业权重分配，不铸币且
保持资金守恒。

普通生产建筑禁止使用 merchant owner。唯一例外是石器期砂金与露天银矿点：无商品投入、无雇员，
必须消耗匹配的金/银矿藏且只产对应金银。市场接受产出时按固定面值增加业主商人资金，并进入
`_explicit_money_mint`、`bullion_money_issued`、金银分项发行额与 closing audit。后期金银矿仍由
industrialist 持有并保留工业投入、矿工和管理岗位。不存在虚空商站铸币分支。

投入边可以是精确 good，也可以声明 category 与最低质量等级。`EconomyCatalog` 将类别展开为按
stable good ID 排列的候选 CSR，并附带 good-level Q16 生产效率。native 在冻结国家科技可用的候选
中按 `price / efficiency` 选择最低有效成本；生产期还要求本地正库存。物理消耗为
`ceil(effective_required / efficiency)`，库存、业主现金与 goods audit 仍记录实际物理数量。
这使早期木材等配方可以直接使用打制石器、青铜、金属或精密工具，不再需要商品转换站；每个输入槽仍按建筑时代设置最低品质，因此探索以后不会再选中打制石器，信息/AI 只接受精密工具。

`upgrade_family_id/upgrade_tier` 编译为稳定 family 目录与逐建筑 tier。BUILD 检查同族最高已解锁
档位，旧档返回 `building_tier_obsolete_for_construction`；生产仍只检查该建筑原始科技，因此旧
owner-lot 继续生产且不会自动转换。快照发布 family、tier、highest available tier 和当前可建状态。
食物与家庭织布各只有 gathering、pottery、guild、steam 四档，蒸汽后不再扩展。

周期开始先按冻结价格计算每栋建筑的投入替换成本、完整工资义务、预期 producer settlement
收入与目标营业利润率，作为诊断和销售后利润分享依据。计划利用率按可售产出的真实售罄率调整，
耐储商品保留 1/32 探测下限，易腐/周期流商品保留 1/6 下限；严重亏损状态机仍是完全停产的唯一入口。生产者自留只在该业主实际生产的单组分生存食品或寒冷衣物之间重新归一化，不再把最低生存额稀释到其无法生产的理想替代品上。

周期开始时仍存活人口先就业；随后业主按本地价购买输入并生产。每个 owner 从统一
`survival_household` 基础量、冻结人口/环境和民族修正计算无财富/价格弹性的生存量，只对主食、蛋白质、蔬果保留饥饿阈值比例，并按寒冷
暴露保留最低衣物；其他需求和超过最低量的产出直接进入 offer。商人按 actual withdrawal/export EMA、目标库存天数和冷启动一日产出计算
库存缺口，以 good-specific `merchant_buy_price_factor_q16`（默认 95%）计价；期初现金保留 25%，
其余预算按缺口价值和稳定 good/group 顺序分配；未获正常采购的可储存余货按本地零售价 20% 托底发行并入库，只有 cycle-flow 余量丢弃。销售后统一分配工资和奖金，居民再用本期收入购买
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
资源边另有 `local/local_and_adjacent` 访问模式。海鱼与淡水鱼储量位于水域格，岸上渔港在冻结
sample boundary 捕获的六邻拓扑上汇总本格+邻格，并按稳定来源顺序扣减真实水格；无需在岸格
复制鱼群，也不会创建跨格 GDScript 经济状态。

世界设置启用测试经济数据时，fixture 先生成资源适配的自给、采集与本地产业 owner-lot，随后
通过 `EconomyFacade.building_job_spec()` 读取 catalog 岗位列并派生 cohort。生成前用
`building_placement_spec()` 的投入/产出数量检查本地食品和衣着净产能，削减重复建筑；不具备最低
承载力的地块不生成人口。人口结构不再作为建筑生成输入；建筑岗位配置变化会直接改变新地图的
职业人口结构。

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

Windows / Godot 4.6.2 / template_release / 2026-07-12，默认固定 `market_cycle_days=5`：
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
日期与 available/pending。它随 PKEJ retention 有界保留，不进入 PKEC、核心 state hash 或
全世界 cohort 常驻布局。

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
跨时代扩展后全目录为 120 goods、259
building types、32 professions、17 household needs 和 8 consumption plans。30 种注册自然资源均至少被一个
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
Inspector 诊断 lane，计入 runtime memory，但不进入 state hash 或 PKEC v12。restore 后保持 `-1`
直到下一次成功生产。该扩展没有修改权威公式或存档字段。

`gold`/`silver` 的 `monetary_issue_value` 默认分别为 800000/10000 money subunits。市场接收
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
回收路径，不新增额外 PKEC 字段。

建筑基础工资不再预付；生产出售后用 owner 销售后资金统一分配。最终欠薪继续记录在
`wage_suspended`/unpaid 报告中并取消奖金，但该标记不代表下一轮自动停产。

居民直接消费不再使用 railway_equipment、oceanic_vessels 或 scientific_instruments 代理交通/科研
服务。前两项在基础设施/服务经济落地前作为明确的无家庭需求资本品保留；scientific_instruments
仍有精密工具生产下游。允许的跨 need 复用仅为 refined_fuel、computers、beverages 和 fur，
Inspector 会聚合显示。需求/计划变更只改变 catalog hash；旧 hash 的 PKEC v12 按现有
`save_catalog_scale_or_capacity_mismatch` 路径拒绝，byte schema 与五日默认 cadence 不变。
生成目录遵守 16 needs、每 need 8 variants、每 variant 4 components 的运行时合同；本轮加入
野味后实际最大 variant 数为 5，最大 component 数仍为 2。聚焦处理量以当前 schema 测试输出为准。

`electricity` 是唯一 `cycle_flow` good。`building_production` 内先运行只产出 cycle-flow 的
utility groups并结算 offers，再运行其他 groups；其余电力在 cell 生产结束时清零并计入 goods
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

以上是默认五日 cadence 证据，不与 auto N=50/N=334 数据混用。

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
