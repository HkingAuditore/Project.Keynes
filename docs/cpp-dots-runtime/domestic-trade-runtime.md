# 国内跨地块市场与运输运行时（Trade V1）

实现入口为 `gdext/src/economy_runtime.{h,cpp}`、`gdext/src/world_ext_economy.cpp`、
`scripts/data/{economy,good,terrain}_profile.gd` 与 `scripts/economy/economy_facade.gd`。
该机制扩展现有“一地块一市场”，但不创建第二套市场或 GDScript 经济状态；库存、商人资金、
贸易规划、在途订单和结算仍由 `NativeEconomyRuntime` 单一写入。

## 权威状态与复杂度

| Store | 内容 | 持久化 |
| --- | --- | --- |
| `TradeTopologyStore` | 六邻接、可贸易通行、进入成本、冻结国家连通分量、拓扑代际 | 否；加载后从地图与国家快照重建 |
| `TradeSignalStore` / `TradeFlowSignalStore` | 稀疏盈余/缺口、价格压力工作集、进出口 EMA | 进出口 EMA 是 PKEC v11 权威状态；规划工作集不保存 |
| `TradePlanStore` | 轮转扫描游标、有界 Dijkstra scratch、候选缓冲、固定容量路线缓存 | 否 |
| `TradeOrderStore` | 稳定订单 ID、路线端点、到达日、物资行 CSR、卖方快照 CSR、货物/现金托管 | 是，PKEC v11 |

常驻复杂度保持为 `O(cell + edge + active_signal + in_flight_order)`。禁止全源最短路、
全市场×全物资候选矩阵或逐路径 Godot Object。路线缓存、信号、候选和订单均受
`EconomyProfile` 固定上限约束。

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
  sample boundary 通过 `capture_economy_trade_topology()` 粗粒度捕获一次。

## 预算化规划

模式由 `trade_runtime_mode=OFF|PROBE|ACTIVE` 控制。OFF 不扫描；PROBE 执行与 ACTIVE 相同的
确定性候选计算但不改变库存、资金、订单或 state hash；ACTIVE 才预留与发运。

规划在上次 `AGGREGATE_PUBLISH` 后形成只读工作集，并由 `economy_should_run()` 暴露为软任务。
`EconomyDailySystem` 继续每 tick 最多一片、默认 0.8 ms 预算；预算转为确定性的扫描 pair 数、
路线搜索数和扩展数，不用墙钟决定模拟结果。规划不申请 WorldClock 屏障；若未完成，下次从
轮转游标继续。当前默认每片扫描 16,384 pair、执行 2 个源路线搜索。

1. 分片扫描 market-major `(cell, good)`，只保留有库存盈余或价格/库存缺口的稀疏信号。
2. 对盈余源运行多目标有界整数 Dijkstra；找到 K 个可盈利目的地或达到扩展上限即停止。
   路线成本与商品无关，可跨商品复用。
3. 用源端减库存、目的端加库存后的现有 Price V3 压力估计交易后价差：
   `expected_profit = quantity * (estimated_destination_price - estimated_source_price)`。
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
trade_settle -> external_ledger -> trade_dispatch -> household_market
-> structural/employment/production -> aggregate_publish
```

发运立即从源 `MarketStore.stock` 移除货物，并按目的地商人人口稳定分摊购买资金扣款；货物和
现金分别进入订单托管。这样当期居民市场只能消费剩余库存/资金，不会重复出售或超额购买。
同一源、目的、对齐到达日的多种商品合并为一个多行 CSR 订单；反向运输始终是另一订单。

原始 ETA 是 `ceil(route_cost / trade_speed)`，到达日向上对齐到首个固定经济提交边界。到达时
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

`get_economy_report()` 提供规划 phase/进度、信号/候选数、接受和拒绝原因、路线扩展、缓存
命中/未命中、国家运力/利用率、在途订单/货物、现金托管、结算滞后及阶段耗时。

## PKEC v11 与兼容性

PKEC v11 在 v10 国家桥格式上增加贸易订单和贸易流 EMA sections，并在 header 保存稳定
`next_order_id` 与已解析贸易配置。路线缓存、拓扑、Dijkstra scratch、未完成扫描和候选不存档。
加载后先恢复 PKCN v1，再恢复 PKEC；贸易拓扑由下一次地图捕获重建。

PKEC v10 可读取，并确定性迁移为“空在途订单、空托管、空贸易 EMA、待重建拓扑”。为避免
新增 good/terrain 贸易字段破坏旧存档，catalog 同时编译 `catalog_compat_hash_v10` 只用于 v10
校验。PKEC v2-v9 仍精确拒绝为 `legacy_countryless_economy_save_unsupported`。

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

## v1 非目标

不含跨国贸易、关税、自贸区、外交、逐边拥堵、运输工资、运输建筑产能、港口或换装。
水域可以作为内容配置的普通贸易地块，但不模拟真正的陆海联运。
