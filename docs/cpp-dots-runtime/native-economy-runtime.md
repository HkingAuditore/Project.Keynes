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
| 企业需求/供给 EMA、成本锚 | C++ 稀疏 `MarketSignalStore` | 仅保存建筑实际引用的 `(cell, good)` 边。 |
| 国内路线、稀疏贸易信号、订单、货物/现金托管、进出口 EMA | C++ `Trade*Store` | 同一冻结国家内预算化规划；PKEC v11 只保存订单/托管/EMA。 |
| 需求、预算、bundle 清算、替代 fallback、商人结算、Price V3 | C++ Market V2 hot loop | 不访问 Godot Object/Callable/Dictionary。 |
| 周期环境快照 | DataCore 环境 slots → C++ Q16 snapshot | 周期 sample day 捕获 temp/moisture/snow/weather，周期内冻结。 |
| catalog 编译 | `EconomyCatalog`/`EconomyFacade` 冷路径 | stable ID 排序后一次性提交 PackedArrays。 |
| 调度和结算屏障 | `EconomyDailySystem`/`WorldClock` | 周期内正常跨日；仅截止日未完成时 same-day catchup。 |
| 查询与存档 I/O | GDScript 薄壳 | Inspector 只读 selected-cell slice-complete snapshot；存档只读 committed boundary，4–16MB byte chunks。 |

不存在大规模 GDScript fallback。原生 ABI 不可用时经济显式 disabled；PROBE 模式
保留 catalog/bootstrap/查询和显式测试能力，但不进入生产 scheduler。

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

- need：优先级、人均基础量、连续财富弹性/上下限、数量环境曲线。
- variant：偏好权重、价格弹性、偏好环境曲线。
- component：good 与每份 bundle 所需数量。
- 同一 need 的 variants 是替代方案；同一 variant 的 components 是必须按比例满足的
  互补 bundle。

每 cohort 每日按优先级重置预算和需求。财富是 `funds/population` 相对
`wealth_reference_per_capita` 的连续定点函数，不形成额外身份分桶。民族以稀疏 need
修正表参与数量计算；温度、湿度、积雪和天气强度通过 17 点 Q16 曲线影响数量或偏好。

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

household market 本身不执行出生、死亡、迁移、就业、工资、税收或生产。国内贸易在同一经济
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

人口 cell snapshot 在 committed boundary 额外返回 cohort-major CSR 预计需求：
`demand_good_offsets`、`demand_good_indices`、`demand_per_capita_daily` 和
`demand_good_stable_ids`。它复用正式清算的财富、环境、替代品与互补品定点内核，固定
`dt_days=1`，只计算预算/库存约束前的预计单位/人/日。当前地块环境由 `DCWorldExt`
直接读取 DataCore slots；查询只使用局部临时数组，不改变 state hash、report、存档或
持久内存布局。

同一查询还返回 `demand_need_offsets/indices`、`demand_need_variant_offsets`、
`demand_variant_component_offsets`、`demand_component_good_indices` 与
`demand_component_per_capita_daily` 的嵌套 CSR。Inspector 据此按 need 分组，将同一 need
下的 variant 标为互为替代，并将同一 variant 的多个 component 标为配套组合；不得从已按
good 汇总的旧列反推分组，因为同一 good 可以属于多个 need。新增列仍是 selected-cell
冷查询输出，不进入 catalog hash、PKEC schema 或持久状态。

世界生成页的“生成测试经济数据”默认关闭。显式启用后使用石器中期科技，只在已发现资源能
支撑配方的地块放置 collector，并只在本地上游齐全时放置 industrial；升级族只放置最高可用档。
随后按 owner/employee 岗位容量聚合 cohort，初始就业和库存保持为零。它是开发 fixture，
不是正式历史人口来源。

## 实测门槛

Windows / Godot 4.6.2 / template_release / 2026-07-11。下表是显式
`market_cycle_days=0` 的自动周期性能档，不代表默认 5 日档：

| 档位 | 样本 | avg | p95 | max | runtime memory | ACTIVE 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10k cells / 200k cohort / 100 goods / 16 needs / N=50 | 2500 | 1.883ms | 2.766ms | 3.126ms | 101.0MB | 通过 |
| 100k cells / 10m cohort / 200 goods / 16 needs / N=334 | 668 | 5.542ms | 6.333ms | 9.394ms | 1680.6MB | 通过 |

错峰把 10M p95 从约 89ms 降至约 4ms；惰性会计清零和按需 merchant rebuild 消除了
周期边界 90/30ms 尖峰。代价是可配置的结算延迟与 reference 误差，详见调度文档。
# Native Building / Employment Runtime（PKEC v11 + PKCN v1）

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
或 owner-lot 人身绑定。业主现金不足时按 owner 全部 role 义务稳定比例支付，相关 owner-lot
本周期停产。工资仍按本地同职业实际就业权重分配，不铸币且保持资金守恒。

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
收入与目标营业利润率，作为诊断和销售后利润分享依据。计划利用率固定为 `Q16_ONE`；亏损不再
缩放岗位需求或产能，实际产能只由到岗、投入、业主资金和资源约束决定。

生产在居民市场之后、周期截止日执行，因此产出下一周期才参与居民消费。业主按本地价购买
输入；商人按 good-specific `merchant_buy_price_factor_q16`（默认 95%）并按本地市场价从高
到低收购，现金耗尽后剩余产出丢弃。建筑采样使用
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
通过 `EconomyFacade.building_job_spec()` 读取 catalog 岗位列并派生 cohort。人口结构不再作为
建筑生成输入；建筑岗位配置变化会直接改变新地图的职业人口结构。

Inspector 首屏通过 `get_population_cell_summary` 只读取人口聚合值；人口需求、市场、建筑与自然
资源明细由可见标签惰性读取，避免点击成本随全局 goods/building catalog 扩张。完整 snapshot 在
Facade/UI 只读传递，不再为缓存和返回值各做一次递归深拷贝。

公共冷路径 `get_building_cell_snapshot` 返回建筑 owner-lot、岗位实到、周期投入/产出/销售、
资源容量/采收及选中地块的 reserve/pending/effective 三列。PKEC v5 的历史字段
`last_resource_generated` 仍为 byte-layout 兼容保留；当前 crop-capacity 目录不依赖正培育。
Inspector 对 capacity 边显示有效容量，对 extract 边显示实际采收。v4 的实际投入成本与实付工资继续用于
利润；v8 另保存 role 合同工资、生活成本、当地均薪、基础工资/奖金、欠薪停产标记和稀疏
LaborMarketStore。亏损不再缩减计划利用率；生产完成后仅将超过目标业主利润的 25% 结为奖金。
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

玩家人口 Inspector 使用独立的 `set_economy_inspector_trace_cell()` 单地块目标。冻结周期中
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
Inspector 诊断 lane，计入 runtime memory，但不进入 state hash 或 PKEC v11。restore 后保持 `-1`
直到下一次成功生产。该扩展没有修改权威公式或存档字段。

`gold`/`silver` 的 `monetary_issue_value` 默认分别为 800000/10000 money subunits。市场接收
建筑产出的金银时不扣既有现金，native 将付款计入 `_explicit_money_mint`；金银随后作为普通
库存参与珠宝、电子等生产且不重复发行。report 分别发布 accepted quantity、issued money 和
`bullion_money_issued`，普通产出仍受 merchant cash cap。merchant 建筑预检只允许单一金/银产出、
严格对应的唯一金/银矿藏、extract 行为且无资源生成；后期矿井可以有雇员和工具输入。

职业消费使用八套结构不同的原型；`survival_household` 是自适应工资的生活成本基准。`luxury`
使用 beverages、fine_clothing、fine_furniture，`status_goods` 使用 jewelry、fur、spices。
需求/计划变更只改变 catalog hash；PKEC v11 byte schema 与五日默认 cadence 不变。

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
