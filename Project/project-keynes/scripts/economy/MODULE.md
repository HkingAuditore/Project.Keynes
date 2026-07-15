# economy — 原生阶层与本地市场模块

> 状态：Market V2 / Price V3 ACTIVE（`production_income_consumption_v4`）。功能、守恒、确定性与
> 200k/10M 性能门槛已通过。范围包含 cohort、商人所有权、消费、本地市场、需求 EMA/价格、环境需求、
> 替代品/互补 bundle、Inspector、BUILDING_GRAPH、冻结国家科技、国内 Trade V1、PKEC v11 流式存档与 PKEJ 分层事件；国家身份、领土、科技和国库由 NativeCountryRuntime 权威持有；不含税、
> 跨国贸易/关税、政治和一般自然人口变化；仅实现缺乏食品/气候所需衣着造成的生存死亡。

## 权威与禁止事项

- C++ `NativeEconomyRuntime` 拥有全部可变经济状态和 hot loop。
- `DCWorldExt` 只组合 runtime 并暴露粗粒度 API 与周期 sample-day 环境快照。
- `EconomyCatalog` 冷启动编译 stable ID/CSR/PackedArrays；`EconomyFacade` 只打包命令和查询。
- `EconomyDailySystem` 是 SUS/WorldClock 薄壳；gameplay/save 只读 committed，Inspector 的选中
  cell 冷查询可读取切片间最新完整 snapshot，并以 `snapshot_source` 标记来源。
- 人口 snapshot 用 cohort-major CSR 返回原生计算的预计单位/人/日；Inspector 先按玩家可见用途
  归并商品，再在组内显示唯一商品行；嵌套 need/variant/component 列只提供用途归组与 `has_bundle` 展示元数据。查询不持久化
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
- `staple_food/protein/produce` 是内部营养与价格分配子篮子，对玩家统一显示“食品”；野味、
  鱼、肉、谷物、采集植物和已解锁加工食物均按替代品展示，即使当前分配量为零也不隐藏。
- 生存满足取“食品总满足”和“气候修正衣着满足”的较小值；高温可把衣着需求降到零。
  周期开始时仍存活人口先参与就业和生产，profile 的 50% 阈值只用于消费后的确定性饥饿死亡，
  不再前置削减劳动力并锁死自给生产。
- 八套职业原型共用九项基础家庭需求，并以基础/舒适/奢侈三档比例及分层财富弹性校准。
  同一 good 跨 need 只允许 refined_fuel、computers、beverages、fur 四种明确多用途；展示层聚合
  数量与支出，不重复渲染。铁路设备、远洋船舶和科学仪器不再代理居民服务消费。
- 商品可由显式库存命令或 BUILDING_GRAPH 生产进入市场。
- 建筑先购买原料并生产；业主按自己的消费计划从单商品需求变体中留用本期所需产出，剩余产出
  才出售给市场，再从销售后资金统一分配基础工资和奖金；居民随后使用本期收入购买本期新商品。
  留用品不产生虚假收入或支出，未消费余量回记来源建筑的丢弃量。最终欠薪继续报告，但不会追溯
  取消已完成生产。
- 商人不能拥有普通生产建筑。例外仅限金银 collector：必须只有一种金/银产出、只消耗严格对应的
  金/银矿藏、使用 extract 模式且不生成资源；允许后期矿井拥有雇员和工具输入。
  市场接受金银时按 `monetary_issue_value` 向业主发行货币，计入
  `explicit_money_mint/bullion_money_issued`，不允许无资源铸币。
- 国内贸易只沿同一冻结国家的可贸易地形运输；发运即托管源货物和目的商人现金，到达边界结算。
- 生产默认 5 日结算周期；`market_cycle_days=0` 才启用按规模自动周期。
- 世界设置中的测试经济 fixture 默认关闭；启用时使用石器中期科技，只在可见资源能支撑配方的
  地块放置 collector，并只在已有全部本地上游产出的地块放置 industrial。升级族只放置当前最高
  可用档。生成器按输出减直接消费品投入计算净产能，以食品 `1300`、衣着 `4`
  GOODS_SCALE/人/日为保守下限；只削减重复建筑并保留每种可用建筑至少一栋。连一人最低需求都
  无法覆盖的地块不生成测试聚落，避免必然停工和死亡。生成顺序固定为建筑 owner-lot → catalog
  岗位汇总 → cohort；初始就业和市场库存均为零，由原生图在后续周期结算。该 fixture 仅用于开发
  测试，不能作为正式历史人口来源。

## 调度

周期 sample day 捕获四类环境 slots，并冻结价格、科技、资源和企业价格信号；建筑先改变本期
资金与库存，居民再据此计算 N 日交易总量。地块
在 N 日内按 cohort 数错峰，提前完成后等待结算日统一发布；只有结算日仍未完成才开启
WorldClock 硬日屏障和 real-frame catchup。独立 ECONOMY_GRAPH 不进入环境 native round。

完整规范见：`native-economy-runtime.md`、`domestic-trade-runtime.md`、`economy-fixed-point-ledger-formulas.md`、
`economy-graph-scheduling.md` 与 `economy-save-migration-sop.md`。
# Building runtime

`BuildingProfile` 位于 `data/economy/buildings/`，由 `EconomyCatalog` 编译进 native catalog。
`EconomyFacade.build/demolish/building_cell_snapshot` 是 GDScript 粗边界；建筑、岗位、生产、所有权
份额和账本只由 C++ 修改。employee role 的 `adaptive` 工资使用当地生活成本与岗位合同工资
EMA；同一 owner 在产品销售后按可用现金比例支付。销售后超过目标业主利润的
25% 形成奖金池。亏损本身不再降低就业需求或计划利用率。生产后只对建筑实际输入/输出边更新
稀疏企业需求、供给和成本锚，并更新稀疏 `(cell, profession)` 劳动市场信号，
供下一周期 Price V3 使用。
`consume_local_resources` 的资源边分为 `extract` 与 `capacity`：前者按本地储量限产并发布负 delta，
后者只限制建筑数量/产能而不扣减储量。农场以旱作耕地、水田或种植园容量生产 crop goods，
不再生成小麦/玉米等自然资源。负 pending delta 会立即压低下一经济周期的有效可采储量以防超采。
自然资源储量单位不与 goods 单位作 1:1 映射；extract 效率由各 BuildingProfile 的资源投入和
总输出共同定义，当前目录按采集方式与技术分为 `2:1` 至 `25:1`，同资源的后期矿井通常高于
早期开采点。多副产品按各输出数量之和计算。新地图 bootstrap 另以 ResourceProfile 的
`init_reserve_scale` 放大初值：农业 capacity 为 `1×`、可再生资源为 `2×`、地质/不可再生资源为
`8×`；它不改变矿脉分布、每日再生公式或原生扣减/守恒逻辑。
选中地块 Inspector 使用 owner-lot 的实际收入、投入成本、工资、资源需求与采收账本显示关系；
人口页通过独立单地块 SELECTIVE 目标读取上次提交周期的人均收支与精确来源，首次选中等待
下一次结算，且不会覆盖调试 trace filter；市场默认只显示价格、库存与无前缀增减值。
GDScript 只附加 catalog 展示名
和配方元数据，不维护第二份建筑账本。
`EconomyFacade.building_type_ids/profession_ids/building_job_spec/building_placement_spec` 只用于
生成期冷路径，把 dense catalog 目录、岗位、投入产出和资源列还原为 stable ID；运行期就业、
生产和工资仍完全由 C++ 权威计算。

`BuildingProfile.upgrade_family_id/upgrade_tier` 编译为稳定 family/tier 目录。国家解锁更高档后，
旧档 BUILD 以 `building_tier_obsolete_for_construction` 拒绝；已有 owner-lot 仍按其原始科技条件
生产，不自动升级或拆除。`subsistence_food` 与 `household_cloth` 都只有 gathering、pottery、
guild、steam 四档，蒸汽档封顶。

生产投入可保持精确 good，也可配置 `input_category_ids + input_min_quality_levels`，或使用
`input_candidate_offsets/input_candidate_good_ids/input_candidate_efficiency_q16` 表达配方专属替代品。
三种模式在单个输入槽互斥；目录把候选按 stable good ID 规范化为 good/效率 CSR。native 只考虑本国科技可用的候选，按库存满足度、有效单位成本和 stable
good ID 稳定选择。`GoodProfile.production_quality_level` 控制最低等级，
`production_efficiency_q16` 把物理库存换算为有效投入。当前工具等级为打制石器 1/50%、青铜工具
2/80%、标准工具 3/100%、精密工具 4/150%，木材、狩猎、行会和部分古典配方可直接使用相应等级，
不再通过交换站把时代商品转换成通用工具。
`GoodProfile.substitution_category_ids` 允许一个 good 同时加入多个配方角色组；每个建筑槽只选择
一个角色，因此多重归类不会自动产生全局互换。`category_id` 仅保留为主角色兼容字段。
`starchy_staple` 同时覆盖地域谷物与马铃薯并供熟制主食槽使用，`cereal_grain` 则保持谷物专属；
食用油和工业润滑剂不共享类目，机器零件从蒸汽时代起直接消费矿物润滑剂。
建筑 snapshot 另以 `group_input_selected_offsets/group_input_selected_good_ids` 返回每个建筑组、每个
输入槽上次实际采购的 good；Inspector 将它标为“当前”。该诊断 lane 不参与权威 state hash 或
PKEC v11 save，restore 后在下一次成功生产前显示为未知。

## 现代内容目录

- 现代基线仍由 `tools/codegen/gen_modern_economy_content.ps1` 生成；脚本支持只读 `-Check`，以及
  只读写 profession/need/plan 的 `-Scope Consumption`。当前全目录为 120 goods、259
  production-method buildings、32 professions、17 needs 和 8 consumption plans。消费重平衡不改
  stable-ID 表或 PKEC v11 字节布局，但会改变 catalog hash，旧 hash 存档按现有 mismatch 路径拒绝。
- `GoodProfile` 额外编译 category、可执行的 `tech.*` `technology_tags`、`stock/cycle_flow` 与金银发行面值；其他标签命名空间仍只作元数据。
- `BuildingProfile` 必须是 collector 或 industrial，owner slots 固定为 1；30 个注册资源全部有
  collector。merchant 业主例外覆盖所有严格匹配真实矿藏的纯金银 collector。
- 30 种资源受 `land/marine_water/freshwater` habitat 门控；海鱼存在海洋水格，淡水/淡水鱼不再是
  DataCore 经济资源。岸上渔业通过 native `local_and_adjacent` 资源边访问并扣减真实水格。
  矿产初值叠加资源局部斑块、
  同族地质省与矿带。栽培作物只存在于 goods，不进入 DataCore resource slots。
- 黄金/白银收购是生产运行时唯一的内生货币发行来源；电力是唯一 cycle-flow，utility prepass
  同周期供给，余量在周期边界清零，并且在家庭公用事业结算完成前不进入家庭能源需求。
- 软件、数字服务、AI 模型、轨道科研、遥测、卫星、深空探测与聚变燃料链已从目录删除；战略矿产
  保留内部 stable ID，并新增 `nuclear_fuel` 加工，核电与同位素反应堆不直接消耗战略矿物材料。
