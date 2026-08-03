# 国内跨地块市场与运输运行时（Trade V1）

实现入口为 `gdext/src/economy_runtime.{h,cpp}`、`gdext/src/world_ext_economy.cpp`、
`scripts/data/{economy,good,terrain}_profile.gd` 与 `scripts/economy/economy_facade.gd`。
该机制扩展现有“一地块一市场”，但不创建第二套市场或 GDScript 经济状态；库存、商人资金、
贸易规划、在途订单和结算仍由 `NativeEconomyRuntime` 单一写入。

## v16 缺口事件与派单仲裁（当前）

稀疏活跃键会在本格确认无库存、需求、短缺、建筑信号和在途订单后删除。每段未响应净缺口是
独立事件，首次成功派单即关闭；下一次结算仍短缺才建立新事件并重新计龄。候选保存计划日与
源/目的价格库存代际，派单时总是重新计算库存安全线、目的净缺口、现金、价格、利润和容量。
同一批次按 `(source, good)` 与 `(destination, good)` 同时扣减共享剩余量，竞争失败记
`ARBITRATED_OUT`，不伪装为源库存失效；同一目的商品一旦成功，后续失败不能覆盖诊断。

## 权威状态与复杂度

| Store | 内容 | 持久化 |
| --- | --- | --- |
| `TradeTopologyStore` | 六邻接、可贸易通行、进入成本、冻结国家连通分量、拓扑代际 | 否；加载后从地图与国家快照重建 |
| `TradeSignalStore` / `TradeFlowSignalStore` | 稀疏盈余/缺口、价格压力工作集、进出口 EMA | 进出口 EMA 是 PKEC v12 权威状态；规划工作集不保存 |
| `TradePlanStore` | 轮转扫描游标、可续跑 Dijkstra heap/stamp/target/expansion cursor、候选缓冲、固定容量路线缓存 | 否 |
| `TradeOrderStore` | 稳定订单 ID、路线端点、到达日、物资行 CSR、卖方快照 CSR、货物/现金托管 | 是，PKEC v12 |

常驻复杂度保持为 `O(cell + edge + active_signal + in_flight_order)`。禁止全源最短路、
全市场×全物资候选矩阵或逐路径 Godot Object。路线缓存、信号、候选和订单均受
`EconomyProfile` 固定上限约束。

固定容量的 `(source,destination) -> route_cost` 缓存现在可跨贸易规划轮次复用；只有
地图贸易拓扑代际、冻结国界拓扑哈希或配置容量变化才会整体失效。缓存不保存路径，
不参与 PKEC/state hash/event hash，命中只替代同一确定性 Dijkstra 结果。bootstrap、
restore 与真实拓扑变化仍显式清空缓存。

`TradeOrderStore` 由持久化的 `arrival_day` 确定性重建“到达日 → order index”CSR 时间桶；
发运、压缩和恢复后重建。结算只遍历已到期桶及其中的待认领现金，不在每个经济边界扫描
全部未来订单。

## 内容与拓扑

- `TerrainProfile.trade_passable` 与正整数 `trade_move_cost` 构成独立贸易通行层。边
  `u -> v` 的成本是进入 `v` 的成本，且两端都必须可贸易通行。陆地内容显式继承现有
  `passable_land/move_cost`；水域默认关闭，可由内容显式开启；零成本可通行是配置错误。
- `GoodProfile.trade_enabled` 控制商品是否进入贸易扫描，
  `transport_load_per_unit_q16` 给出单位货物的 Q16 运力负载。`cycle_flow` 商品强制禁运。
- v1 的 `trade_zone_id` 等于冻结的 `cell_country`。路径上的每个地块必须属于同一非中立国家；
  国界/地形变更只使新规划失效，已经发运的订单按出发契约完成。
- `MapData` 只提供静态六邻接和 256 项 terrain LUT；它不是贸易状态 owner。生产路径在经济
  初始化时由 `MapGenerator` 在 economy configure 后、bootstrap 前通过
  `capture_economy_trade_topology()` 粗粒度捕获一次。非 `OFF` 模式下捕获失败会使本次经济
  初始化显式失败；启动报告必须满足 `trade_topology_ready=true` 且 topology generation 非零。

## 预算化规划

模式由 `trade_runtime_mode=OFF|PROBE|ACTIVE` 控制。OFF 不扫描；PROBE 执行与 ACTIVE 相同的
确定性候选计算但不改变库存、资金、订单或 state hash；ACTIVE 才预留与发运。
默认 profile 与 C++ 缺省值均为 `ACTIVE`；`OFF/PROBE` 必须由测试或特殊配置显式指定。

规划在上次 `AGGREGATE_PUBLISH` 后形成只读工作集，并由 `economy_should_run()` 暴露为软任务。
`EconomyDailySystem` 继续每 tick 最多一片、默认 0.8 ms 预算；预算转为确定性的扫描 pair 数、
路线搜索数和扩展数，不用墙钟决定模拟结果。规划不申请 WorldClock 屏障；若未完成，下次从
轮转游标继续。当前 profile 默认每片扫描 4,096 pair、最多完成 32 个源路线搜索；路线阶段另有
每个 native slice 256 次有效 Dijkstra 扩展的总上限，一个 source 未完成时保留 heap、stamp、
accepted/pending target 和 expansion cursor 到下一片。

计划失效只看规范化贸易拓扑内容哈希与冻结 `cell → country` 归属哈希。拓扑内容哈希只包含六邻接、
由 terrain LUT 映射后的 `passable` 和 `enter_cost`，不包含原始 `terrain_id`；因此季节性地形重分类若不改变
贸易通行语义，不会丢弃未完成扫描。国家现金、国库物资或科技变化造成的通用 country generation 增长也
不重置路线扫描。实际通行/成本或国界变化仍会确定性失效并重建连通分量。

1. 分片扫描 market-major `(cell, good)`，只保留有库存盈余或价格/库存缺口的稀疏信号；未解锁 good、禁运 good、`cycle_flow` good 不进入贸易扫描。
2. 对盈余源运行多目标有界整数 Dijkstra；找到 K 个可盈利目的地或达到 source 扩展上限即停止。
   每个 native slice 最多消费 256 次有效扩展，未完成搜索跨 slice 保留原优先队列顺序；路线成本
   与商品无关，可跨商品复用。
3. 用源端减库存、目的端加库存后的现有 Price V3 压力估计交易后价差：
   `expected_profit = quantity * (estimated_destination_price - estimated_source_price)`。普通贸易仍要求达到最小 margin 与正利润；若目的地存在严重 survival / 生产投入 relief pressure，且估计价差非负，则允许零价差 relief route 生成候选，使用合成正收益只参与排序和 density，避免 price cap 把救济运输全部卡死。
4. 运力工作量为
   `quantity * transport_load_per_unit_q16 * route_cost`。每国每周期的区域运力池来自冻结
   商人人口乘 `trade_capacity_per_merchant_population_q16`，不跨周期结转。
5. 候选按单位运力利润、总利润、路线成本、源、目的、good ID 稳定排序；再按源库存、目的
   商人资金、国家运力和订单上限裁剪。全部乘法使用 128 位中间值与现有饱和策略。

当前生产实现使用单一确定性候选路径；本地市场 worker 不参与贸易 store 写入，因此
scalar/worker 的 authoritative hash 相同。未来若并行路线搜索，worker 只能写各自有界缓冲，
最终稳定排序和所有预留仍必须在主线程完成。

## 订单与经济边界

经济边界顺序为：

```text
trade_settle -> external_ledger -> building_employment -> building_production
-> household_market -> trade_dispatch -> structural_commit -> aggregate_publish
```

到货先进入目的市场，可参与本期本地清算；新出口必须等待所有本地家庭完成本期购买。派发时
再次按最新 household/business demand EMA、30 日基线乘 good-specific 比例后的有效库存天数、survival/input relief pressure 和生产投入 reserve 计算源地保留量，
只从其上的真实余量移除货物；普通路线再次检查 margin/profit，relief route 仍只允许非负价差，并按目的地商人人口稳定分摊购买资金扣款；货物和现金分别进入
订单托管，不会重复出售或超额购买。
同一源、目的、对齐到达日的多种商品合并为一个多行 CSR 订单；反向运输始终是另一订单。

ETA 是 `departure_day + ceil(route_cost / trade_speed)`，按日处理，不再向上对齐本地五日结算边界。到达时
先把货物放入目的市场，因此可参与当期本地市场；价格仍只由 Price V3 更新，贸易代码不直接
写价。现金按发运时卖方 merchant handle/人口权重支付；handle 失效时重绑定到源地块当前商人，
仍无人接收则订单进入 `WAITING_RECEIVER`，货物不重复交付，现金保留为可审计托管并在后续边界
重试。

守恒口径扩展为：

```text
goods = market stock + country treasury goods + in-transit cargo
money = cohort funds + country cash treasury + trade cash escrow
```

在途货物、托管现金、结算滞后和进出口 EMA 均进入报告；贸易订单的 dispatch/arrival 进入
PKEJ economy journal，但不逐笔灌入通用 gameplay event ring。

## 查询与报告

`get_market_cell_snapshot(cell)` 增加逐 good 的贸易启用/负载、进出口 EMA、入境/出境在途量，
以及地块级托管金额和下一到达日。`get_trade_orders_for_cell(cell, offset, limit)` 只返回与一个
地块相关的分页订单和物资行 CSR；禁止 UI 请求全局订单矩阵。

`get_economy_report()` 提供规划 phase、scan/route cursor 与 total、source/destination 信号数、
当前 source 身份、route search active、单 source expansion cursor、每片 expansion 配额、
pending/accepted target、拓扑哈希、规范化拓扑变化/计划重置计数和最近重置原因，以及
信号/候选数、接受和拒绝原因、路线扩展、缓存命中/未命中、国家运力/利用率、
在途订单/货物、现金托管、结算滞后及阶段耗时。CSV v16 summary 同步保留这些活性字段，并增加事件、代际、仲裁和真实库存失败诊断。

## PKEC v12 与兼容性

PKEC v11 在 v10 国家桥格式上增加贸易订单和贸易流 EMA sections，并在 header 保存稳定
`next_order_id` 与已解析贸易配置。路线缓存、拓扑、Dijkstra scratch、未完成扫描和候选不存档。
加载后先恢复当前 PKCN v4，再恢复 PKEC v29；贸易拓扑由下一次地图捕获重建。

PKEC v12 增加企业停产状态、连续计数、采购意图容量、实际利润率、实际出库 EMA 和对应策略参数。
参数一致的 v11 ACTIVE 才可迁移并将新增字段初始化为确定性默认值；当前 12.5% / 30 日分档库存基线商人策略
与旧 v11 的 25% / 1 日隐式默认值不一致；当前策略为 12.5% 现金保留与 30 日分档库存基线，因此旧默认档明确返回
`save_business_policy_profile_mismatch`。ACTIVE 仍严格拒绝 v11 PROBE
（`save_trade_profile_mismatch`）和 v10（`active_trade_rejects_v10_economy_save`）。
PKEC v2-v9 仍精确拒绝为 `legacy_countryless_economy_save_unsupported`。

## 2026-07-13 release 基准

Windows / Godot 4.6.2 / `template_release`，`tests/economy_runtime_bench.gd -- --trace-off
--trade-active`：

| 场景 | 贸易规划 | 整体经济 p95 | runtime memory |
| --- | --- | ---: | ---: |
| 10k cells / 200k cohorts / 100 goods / N=50 | 69 个含路线搜索样本：slice p95 0.691ms，core p95 0.359ms | 3.386ms | 97.1MB |
| 100k cells / 10M cohorts / 200 goods / N=334 | 首规划 core 0.273ms | 6.623ms | 1672.8MB |

同次 100k OFF 为 p95 6.232ms、1667.3MB；ACTIVE 场景即使包含更强的短缺/替代压力，p95 增量
6.3%，新增常驻内存约 5.5MB，分别低于 15% 与 128MiB 门槛。OFF 与 ACTIVE 使用不同市场价/库存
分布，因此该对比是压力上界记录，不替代后续同状态 A/B。规划 core 采用确定工作单元；slice
p95 包含 native report/bridge 开销。

## 交易后报价与数量裁剪（2026-07-18）

候选不再以完整 `min(source_surplus, destination_gap)` 做一次报价后整批接受或拒绝。运行时固定源/目的
当前库存，对候选数量做确定性整数二分，寻找交易后仍满足条件的最大数量：普通路线要求正价差且
达到 `trade_min_margin_q16`，relief 路线要求价差非负。价格按“源库存减数量、目的库存加数量”重新
估计，因此批量把两地价格推过头时会缩量成交，而不是让生产地完全收不到贸易现金。

dispatch 在本地居民结算完成后，按最新源地保护库存、目的商人现金和国家运力裁剪，再执行同一盈利
数量检查。诊断把无价差与利润率不足分开报告，并统计数量裁剪与 relief 候选：
`trade_rejected_no_spread`、`trade_rejected_margin`、`trade_quantity_profit_clips`、
`trade_relief_candidates`。这些计数不进入存档或权威 hash。

默认每 slice 路线源搜索预算由 2 提高到 16。2400 地块基准中单次扫描约产生 3.5k 个源信号；旧实现
还会等全部源搜索结束才形成首批 `ready_candidates`，即使每个候选本身盈利也会多年无法派发。现在
每个经济边界把自上次结算以来积累的确定性候选块稳定排序并交给 dispatch，路线 cursor 继续前进；
dispatch 的二次价格、库存、现金、运力和拓扑检查保证部分发布不会超卖，cursor 则保证最终公平。

## v1 非目标

不含跨国贸易、关税、自贸区、外交、逐边拥堵、运输工资、运输建筑产能、港口或换装。
水域可以作为内容配置的普通贸易地块，但不模拟真正的陆海联运。
## 2026-07-18 bounded planner completion

The profile default planning slice permits 32 completed route searches (valid
range `1..256`), while the native slice as a whole is capped at 256 effective
Dijkstra expansions. Before route expansion, signals are deterministically grouped by
`(country, good)` and pruned to the four cheapest/highest-quantity sources and
the eight highest-price/highest-quantity destinations. Existing Dijkstra route
validation, source local-demand reserve, destination gap, profit clipping,
escrow, capacity, and arrival contracts remain authoritative.

This is bounded candidate selection, not a topology shortcut: completed full
scans advance and restart from fresh frozen signals, while final dispatch can
still be zero when no route survives the current profit/stock/cash constraints.
The resumable route cursor is transient planner state; no PKEC field was added.
## 2026-07-20 sparse planner and relief routes

Trade planning no longer scans `market_count * good_count`. The existing market
and building goods loops append sparse `(cell, good)` keys when stock, demand,
price bounds, input reserves, EMA state, or in-flight orders make the pair
active. Each five-day boundary may dispatch the completed candidate prefix;
stable cursors and deterministic ordering preserve fairness.

The export floor is the maximum of the production-input reserve, five days of
realized withdrawal, and 50 percent of merchant target inventory. At most 25
percent of source stock is offered. The import fill target is the maximum of the
production reserve and 50 percent of merchant target inventory, with in-flight
cargo deducted from the gap.

Relief pressure is the maximum of survival shortage, unfunded desired business
demand, production-reserve shortage, and price-cap pressure. Ordinary routes
still require a non-negative spread and 5 percent minimum margin. Relief routes
may use zero spread but never negative spread. Source stock, destination merchant
cash escrow, country transport capacity, topology, and conservation are
revalidated at dispatch.

Diagnostic-only sparse clocks record signal age and first dispatch delay. Older
signals sort ahead of newer destinations and candidates. Reports and CSV expose
the maximum age, maximum first-dispatch delay, and signals that exceed the
configured 15-day response target without dispatch; these clocks do not enter
PKEC or the authoritative state hash.
