# economy — 原生阶层与本地市场模块

> 状态：Market V2 ACTIVE（`frozen_sample_linear_v1`）。功能、守恒、确定性与
> 200k/10M 性能门槛已通过。范围包含 cohort、商人所有权、消费、本地市场、需求 EMA/价格、环境需求、
> 替代品/互补 bundle、Inspector、BUILDING_GRAPH 与 PKEC v3 流式存档；不含税、
> 贸易、政治和人口自然变化。

## 权威与禁止事项

- C++ `NativeEconomyRuntime` 拥有全部可变经济状态和 hot loop。
- `DCWorldExt` 只组合 runtime 并暴露粗粒度 API 与周期 sample-day 环境快照。
- `EconomyCatalog` 冷启动编译 stable ID/CSR/PackedArrays；`EconomyFacade` 只打包命令和查询。
- `EconomyDailySystem` 是 SUS/WorldClock 薄壳；gameplay/save 只读 committed，Inspector 的选中
  cell 冷查询可读取切片间最新完整 snapshot，并以 `snapshot_source` 标记来源。
- 人口 snapshot 用 cohort-major CSR 返回原生计算的预计单位/人/日；查询不持久化
  cohort×good 矩阵，也不修改 state hash。
- 禁止把 goods/cohort 放回 MapData/component schema，禁止 GDScript 全世界遍历或逐 cohort setter。
- 建筑生产和临时固定工资由 BUILDING_GRAPH 直接维护守恒账本；未来税收仍必须走原生守恒边界。

## V2 资源

- `GoodProfile`：价格、EMA、目标库存、短缺/库存权重、日涨跌幅。
- `ProfessionProfile`：职业 stable ID 与默认 consumption plan；人口地块必须能解析 merchant。
- `EthnicityProfile`：稀疏 need 数量修正。
- `NeedProfile`：优先级、基础数量、连续财富函数、环境数量曲线、替代 variants 与互补 components。
- `ConsumptionPlanProfile`：按稳定 need ID 组合消费计划。
- `EnvironmentDemandCurveProfile`：temp/moisture/snow/weather 的 17 点 Q16 曲线。
- `EconomyProfile`：尺度、slice/worker、自动/强制市场周期、每片 cohort 预算、商人职业、财富参考值和 OFF/PROBE/ACTIVE。

## 行为契约

- 一地块一市场；库存由该地块全部商人 cohort 按人口共同持有。
- 人口非零但无商人时，从最大非商人 cohort 转 1 人并按比例转资金。
- 购买资金直接进入商人 cohort，无 `market_cash`。
- 商人正常消费；每日需求/预算重置；同 tick 最多一次替代 fallback。
- 同一 variant 的 components 是互补 bundle；不同 variants 是替代品。
- 商品可由显式库存命令或 BUILDING_GRAPH 生产进入市场。
- 生产默认 5 日结算周期；`market_cycle_days=0` 才启用按规模自动周期。
- 世界设置中的测试经济 fixture 默认关闭；启用时在可通行陆地同步生成 cohort、市场库存和
  四类压缩建筑组。生成顺序固定为建筑 owner-lot → catalog 岗位汇总 → cohort → 市场库存，
  仅用于开发测试，不能作为正式历史人口来源。

## 调度

周期 sample day 捕获四类环境 slots，并从冻结资金/人口/价格计算 N 日交易总量。地块
在 N 日内按 cohort 数错峰，提前完成后等待结算日统一发布；只有结算日仍未完成才开启
WorldClock 硬日屏障和 real-frame catchup。独立 ECONOMY_GRAPH 不进入环境 native round。

完整规范见：`native-economy-runtime.md`、`economy-fixed-point-ledger-formulas.md`、
`economy-graph-scheduling.md` 与 `economy-save-migration-sop.md`。
# Building runtime

`BuildingProfile` 位于 `data/economy/buildings/`，由 `EconomyCatalog` 编译进 native catalog。
`EconomyFacade.build/demolish/building_cell_snapshot` 是 GDScript 粗边界；建筑、岗位、生产、所有权
份额和账本只由 C++ 修改。当前 `fixed` 工资按实际到岗人数和周期天数从业主转给雇员，
业主现金不足时记录 `building_wages_unpaid`。
`EconomyFacade.building_job_spec` 只用于生成期冷路径，把 dense catalog 岗位列还原为 stable
profession ID；运行期就业和工资仍完全由 C++ 权威计算。
