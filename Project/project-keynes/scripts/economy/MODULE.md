# economy — 原生阶层与本地市场模块

> 状态：Market V2 / Price V3 ACTIVE（`frozen_sample_adaptive_price_v2`）。功能、守恒、确定性与
> 200k/10M 性能门槛已通过。范围包含 cohort、商人所有权、消费、本地市场、需求 EMA/价格、环境需求、
> 替代品/互补 bundle、Inspector、BUILDING_GRAPH、冻结国家科技、国内 Trade V1、PKEC v11 流式存档与 PKEJ 分层事件；国家身份、领土、科技和国库由 NativeCountryRuntime 权威持有；不含税、
> 跨国贸易/关税、政治和人口自然变化。

## 权威与禁止事项

- C++ `NativeEconomyRuntime` 拥有全部可变经济状态和 hot loop。
- `DCWorldExt` 只组合 runtime 并暴露粗粒度 API 与周期 sample-day 环境快照。
- `EconomyCatalog` 冷启动编译 stable ID/CSR/PackedArrays；`EconomyFacade` 只打包命令和查询。
- `EconomyDailySystem` 是 SUS/WorldClock 薄壳；gameplay/save 只读 committed，Inspector 的选中
  cell 冷查询可读取切片间最新完整 snapshot，并以 `snapshot_source` 标记来源。
- 人口 snapshot 用 cohort-major CSR 返回原生计算的预计单位/人/日；查询不持久化
  cohort×good 矩阵，也不修改 state hash。
- 禁止把 goods/cohort 放回 MapData/component schema，禁止 GDScript 全世界遍历或逐 cohort setter。
- 建筑生产、自适应生活工资与 owner-lot 利润奖金由 BUILDING_GRAPH 直接维护守恒账本；未来税收
  仍必须走原生守恒边界。
- 六邻贸易拓扑、稀疏规划、路线缓存、在途订单和托管由 NativeEconomyRuntime 持有；MapData
  只在经济边界提供邻接与 terrain LUT，UI 只允许分页查询单地块订单。

## V2 资源

- `GoodProfile`：价格、居民/企业/供给/成本 EMA、需求弹性、目标库存、各压力权重、日涨跌幅、
  `trade_enabled` 与单位运输负载。
- `ProfessionProfile`：职业 stable ID 与默认 consumption plan；人口地块必须能解析 merchant。
- `EthnicityProfile`：稀疏 need 数量修正。
- `NeedProfile`：优先级、基础数量、生活成本 Q16 权重、连续财富函数、环境数量曲线、替代
  variants 与互补 components。
- `ConsumptionPlanProfile`：按稳定 need ID 组合消费计划。
- `EnvironmentDemandCurveProfile`：temp/moisture/snow/weather 的 17 点 Q16 曲线。
- `EconomyProfile`：尺度、slice/worker、自动/强制市场周期、每片 cohort 预算、商人职业、财富参考值，
  以及独立的市场/贸易 OFF/PROBE/ACTIVE 与确定性贸易工作预算。

## 行为契约

- 一地块一市场；库存由该地块全部商人 cohort 按人口共同持有。
- 人口非零但无商人时，从最大非商人 cohort 转 1 人并按比例转资金。
- 购买资金直接进入商人 cohort，无 `market_cash`。
- 商人正常消费；每日需求/预算重置；同 tick 最多一次替代 fallback。
- 同一 variant 的 components 是互补 bundle；不同 variants 是替代品。
- 商品可由显式库存命令或 BUILDING_GRAPH 生产进入市场。
- 国内贸易只沿同一冻结国家的可贸易地形运输；发运即托管源货物和目的商人现金，到达边界结算。
- 生产默认 5 日结算周期；`market_cycle_days=0` 才启用按规模自动周期。
- 世界设置中的测试经济 fixture 默认关闭；启用时在可通行陆地同步生成 cohort、市场库存和
  资源适配的专业化建筑。每个聚落保留配送中心以保证商人和基础就业；collector 仅在本地 reserve
  能支撑配方时生成，数量受资源容量和测试上限约束；industrial 只落在少量确定性专业化地块，并
  优先选择已有本地上游产出的地块。生成顺序固定为建筑 owner-lot → catalog 岗位汇总 → cohort →
  市场库存；职业 cohort 只随本地实际 owner/employee 岗位生成，
  仅用于开发测试，不能作为正式历史人口来源。

## 调度

周期 sample day 捕获四类环境 slots，并从冻结资金/人口/价格计算 N 日交易总量。地块
在 N 日内按 cohort 数错峰，提前完成后等待结算日统一发布；只有结算日仍未完成才开启
WorldClock 硬日屏障和 real-frame catchup。独立 ECONOMY_GRAPH 不进入环境 native round。

完整规范见：`native-economy-runtime.md`、`domestic-trade-runtime.md`、`economy-fixed-point-ledger-formulas.md`、
`economy-graph-scheduling.md` 与 `economy-save-migration-sop.md`。
# Building runtime

`BuildingProfile` 位于 `data/economy/buildings/`，由 `EconomyCatalog` 编译进 native catalog。
`EconomyFacade.build/demolish/building_cell_snapshot` 是 GDScript 粗边界；建筑、岗位、生产、所有权
份额和账本只由 C++ 修改。employee role 的 `adaptive` 工资使用当地生活成本与岗位合同工资
EMA；同一 owner 现金不足时比例支付并令其 owner-lot 本周期停产。销售后超过目标业主利润的
25% 形成奖金池。亏损本身不再降低就业需求或计划利用率。生产后只对建筑实际输入/输出边更新
稀疏企业需求、供给和成本锚，并更新稀疏 `(cell, profession)` 劳动市场信号，
供下一周期 Price V3 使用。
`consume_local_resources` 的资源边分为 `extract` 与 `capacity`：前者按本地储量限产并发布负 delta，
后者只限制建筑数量/产能而不扣减储量。农场以旱作耕地、水田或种植园容量生产 crop goods，
不再生成小麦/玉米等自然资源。负 pending delta 会立即压低下一经济周期的有效可采储量以防超采。
选中地块 Inspector 使用 owner-lot 的实际收入、投入成本、工资、资源需求与采收账本显示关系；
人口页通过独立单地块 SELECTIVE 目标读取上次提交周期的人均收支与精确来源，首次选中等待
下一次结算，且不会覆盖调试 trace filter；市场默认只显示价格、库存与无前缀增减值。
GDScript 只附加 catalog 展示名
和配方元数据，不维护第二份建筑账本。
`EconomyFacade.building_type_ids/profession_ids/building_job_spec/building_placement_spec` 只用于
生成期冷路径，把 dense catalog 目录、岗位、投入产出和资源列还原为 stable ID；运行期就业、
生产和工资仍完全由 C++ 权威计算。

## 现代内容目录

- 现代基线仍由 `tools/codegen/gen_modern_economy_content.ps1` 生成；跨时代手写扩展在其上形成
  164 goods、203 buildings、39 professions、15 needs，并保留原有 stable IDs。
- `GoodProfile` 额外编译 category、可执行的 `tech.*` `technology_tags`、`stock/cycle_flow` 与金银发行面值；其他标签命名空间仍只作元数据。
- `BuildingProfile` 必须是 collector 或 industrial，owner slots 固定为 1；37 个资源全部有 collector。
- 41 种资源受 `land/marine_water/freshwater` habitat 门控；海鱼存在海洋水格，淡水资源存在
  湖泊水格或河流格。岸上渔业/水厂通过 native `local_and_adjacent` 资源边访问并扣减真实水格。
  矿产初值叠加资源局部斑块、
  同族地质省与矿带。栽培作物只存在于 goods，不进入 DataCore resource slots。
- 黄金/白银收购是生产运行时唯一 mint 来源；电力是唯一 cycle-flow，utility prepass 同周期供给，
  余量在周期边界清零。以上行为均由 C++ BUILDING_GRAPH 执行。
