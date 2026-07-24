# economy — 原生阶层与本地市场模块

> 状态：Market V2 / Price V4 ACTIVE（`production_income_consumption_v12`）。功能、守恒、确定性与
> 200k/10M 性能门槛已通过。范围包含 cohort、商人所有权、消费、本地市场、需求 EMA/价格、环境需求、
> 替代品/互补 bundle、Inspector、BUILDING_GRAPH、冻结国家科技、国内 Trade V1、PKEC v19 流式存档与 PKEJ 分层事件；国家身份、领土、科技和国库由 NativeCountryRuntime 权威持有；不含税、
> 跨国贸易/关税、政治、年龄与家庭结构；自然出生和死亡由原生 household/structural 路径处理。

> 2026-07-18 平衡口径：贸易使用稳定 `base_terrain`；石器食物保持 30 日商人库存目标；
> 满意度公开字段是“食品与气候衣着的较低值”的生存满足度。黏土、盐、石油是静态地质存量，
> 肥沃土壤缓慢恢复，伐木只发布开采 delta、不再由建筑生成森林。

> v16：建筑采用 ACTIVE/SUSPENDED_LOSS/RECOVERY_PROBE 三态；商人是本地聚合债权池而非普通
> 业主职业，5% 一次性溢价、六期偿还。自产只保留生存食品和寒冷最低衣物，实际消费价值进入
> 次期经济收益但不能偿债。贸易短缺按事件计龄并执行源库存/目的缺口批次仲裁。测试 bootstrap
> 按 50% 可持续承载人口和 75% 利用率反推最小生存链，剩余人口进入 unemployed cohort。

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
- `BUILDING_PLAN` 由 C++ 按 active-cell CSR 做两遍 continuation（经济计划、投入 reserve）；
  `building_cells_per_slice=0` 确定性采用 256 个 active cell。阶段 cursor 与计划缓存只属周期
  临时状态，不进入 PKEC 或权威 hash，GDScript 只转发 profile 和调度 report。
- 建筑生产、自适应生活工资与 owner-lot 利润奖金由 BUILDING_GRAPH 直接维护守恒账本；未来税收
  仍必须走原生守恒边界。
- `owner_slots_per_building` 是正整数物理容量；普通企业通常为 1，家庭式采集/狩猎单位可用多个
  同职业共同经营岗位。活跃 owner-lot 的 owner required 等于物理容量，计划利用率只缩放 employee required 与产量；所有填充仍受对应 cohort 人口约束。
- 六邻贸易拓扑、稀疏规划、路线缓存、在途订单和托管由 NativeEconomyRuntime 持有；MapData
  只在经济初始化边界提供邻接与 terrain LUT。`MapGenerator` 在 economy configure 后、
  bootstrap 前捕获一次拓扑；非 OFF 模式捕获失败即中止本次经济初始化。UI 只允许分页
  查询单地块订单。

## V2 资源

- `GoodProfile`：价格、居民/企业/供给/成本 EMA、需求弹性、目标库存、各压力权重、日涨跌幅、
  `trade_enabled` 与单位运输负载。
- `ProfessionProfile`：职业 stable ID、默认 consumption plan 和 Q32 出生/死亡率；人口地块必须能解析 merchant 与 unemployed。
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
- 商人正常消费；企业采购开始冻结现金并保留 12.5%，按实际出库/出口 EMA 形成的库存缺口价值分配预算；生产者结算价严格使用商品 `merchant_buy_price_factor_q16`（默认 `62259/65536≈95%`）作为零售价比例，短缺只影响采购量和优先级，不能把收购系数抬到 100%；同 tick 最多一次替代 fallback。
- 同一 variant 的 components 是互补 bundle；不同 variants 是替代品。
- `staple_food/protein/produce` 是内部营养与价格分配子篮子，对玩家统一显示“食品”；野味、
  鱼、肉、谷物、采集植物和已解锁加工食物均按替代品展示，即使当前分配量为零也不隐藏。
- 生存满足取“食品总满足”和“气候修正衣着满足”的较小值；高温可把衣着需求降到零。
  周期开始时仍存活人口先参与就业和生产，profile 的 50% 阈值只用于消费后的确定性饥饿死亡，
  不再前置削减劳动力并锁死自给生产。
- cohort 出生量按人数、`birth_rate_q32` 和当前生存满足率计算；默认年出生率 3.0%、自然死亡率
  2.5%，健康人口长期净增长目标约 0.5%。同地块同民族的出生贡献在 worker 内聚合，经 Q32
  确定性哈希舍入后于 `STRUCTURAL_COMMIT` 加入 `unemployed|eth`，不携带资金且不在同周期招聘。
- 九套在业职业原型加一套失业者生存原型；在业原型共用九项基础家庭需求，并以基础/舒适/奢侈三档比例及分层财富弹性校准。猎人使用独立的
  `hunter_household`，保留职业装备但移除农业型家庭的交通和娱乐需求，并降低基础/舒适消费尺度。
  同一 good 跨 need 只允许 refined_fuel、computers、beverages、fur 四种明确多用途；展示层聚合
  数量与支出，不重复渲染。铁路设备、远洋船舶和科学仪器不再代理居民服务消费。
- 商品可由显式库存命令或 BUILDING_GRAPH 生产进入市场。
- 建筑先按就业、输入资金和资源计算采购意图，再按本地输入库存计算实际产能；缺货输入保留受约束补货意图。生产食物的业主按主食、蛋白质、蔬果总生存热量池留用产出；精确消费变体优先，剩余自产食物可跨三类食品作为紧急热量，但不抬高普通需求满意度。衣物仍只按寒冷暴露留用最低数量，剩余产出
  才出售给市场，再从销售后资金统一分配基础工资和奖金；居民随后使用本期收入购买本期新商品。
  留用品不产生虚假收入或支出，未消费余量回记来源建筑的丢弃量。最终欠薪继续报告，但不会追溯
  取消已完成生产。家庭清算会保留 ACTIVE 企业按已到岗业主比例与计划利用率计算的下一周期投入
  营运资金；市场库存只按整套互补配方可执行的共同容量预留下周期物理投入，非生存加工不得提前锁住生存食物；居民消费和国内出口只能使用预留以上库存。
  商人采购目标以 `max(可行日需求, 实际出库 EMA, 平滑供给下限) + 出口 EMA` 乘 good-specific 有效库存天数，并至少覆盖预留缺口；生存品供给下限为平滑日产量的 1/2，其他耐储品为 1/4，配置库存天数和目标量级不缩小。现金不足时按生存品、居民短缺、生产投入 reserve 缺口提高预算权重；权重只改变购买顺序，总预算仍以真实采购价值为上限。仅目标库存的剩余缺口可按冻结本地零售价的 20% 向生产者发行托底货币并入库；超过目标的余量进入 discard。电力等 cycle-flow 不能托底入库。
  国内贸易对每个目的地冻结同一笔现金预算：`商人正现金 - 既有订单预留 - 12.5% 营运底线`。候选裁量、利润裁剪和最终扣款共享这笔余额，生存品与关键投入也不得突破底线。
  运行时报告、市场快照和 Economy CSV v19 提供商人现金、库存零售/清算价值、总商业资产、采购毛利、贸易买卖现金、经营流出、流动性覆盖率和采购金额加权有效收购系数；这些字段只读派生，不进入 PKEC v19 或确定性哈希。
- 默认 `building_output_efficiency_q16=131072`（2 倍）统一提高所有建筑的物资产出；建设材料、生产投入、自然资源消耗、岗位与工资保持目录原值。倍率在 native 冷路径载入输出列时应用，不改变 building catalog hash 或 PKEC 字节结构。

- 自适应工资的可负担上限使用当前冻结价格下的“满产日收入”，先扣除日投入并预留目标营业利润，再按员工槽位折算；不得再把整个 epoch 的收入直接当作单日工资依据。亏损停产建筑使用同一反事实日收入报价，停产期间岗位目标为零。
- 国内贸易先取源地真实盈余与目的地缺口，再用确定性整数二分裁剪到交易后仍满足利润率的最大数量；relief 路线只要求交易后价差非负。发运前按最新库存、现金和运力再次裁剪，避免整批候选因一次过量报价被全部拒绝。
- 商人不能拥有普通生产建筑。例外仅限金银 collector：必须只有一种金/银产出、只消耗严格对应的
  金/银矿藏、使用 extract 模式且不生成资源；允许后期矿井拥有雇员和工具输入。
  市场接受金银时按 `monetary_issue_value` 向业主发行货币，计入
  `explicit_money_mint/bullion_money_issued`，不允许无资源铸币。
- 国内贸易默认 ACTIVE，只沿同一冻结国家的可贸易地形运输；发运即托管源货物和目的商人现金，到达边界结算。
- 生产周期固定为五日滚动相位；世界规模只改变每日到期桶的工作量，不再自动扩大周期。
- 世界设置中的测试经济 fixture 默认关闭；启用时使用石器中期科技，只在可见资源能支撑配方的
  地块放置 collector，并只在已有全部本地上游产出的地块放置 industrial。石器本地链使用保守的
  多建筑容量基线：每格先配置两座工匠经营的公共火塘和一座石器打制工坊，狩猎营地最多十二座，再交给承载
  平衡器处理；单座石器工坊日产 `220`、家庭织造棚日产 `110`，不改变自然资源储量或增长率。
  升级族只放置当前最高可用档。生成器按输出减直接消费品投入计算净产能，以食品 `1300`、衣着 `4`
  GOODS_SCALE/人/日为保守下限。每格产能校准人口取岗位、净食品、净衣着三种容量的最小值并封顶
  `300`；平衡器保留每种可用建筑至少一栋，只把重复建筑削减到该承载目标。测试设置默认采用
  “资源分层混合”，按产能校准人口、生产输入链覆盖率和本地可见资源相对丰度排序有效聚落，
  从弱到强以确定性分位分配 `1x/10x/100x/500x`，让同一世界同时出现十人、百人、千人、万人级
  地块；也可手动选择统一倍率。人口倍率同时应用于完整生产链建筑和商栈，职业人口按放大后的真实
  岗位配比生成，不再用 unemployed cohort 填充规模。所有当地资源允许的石器 collector、矿场与其
  输入闭合的加工链至少保留一组，不再裁剪“非生存”产业。初始市场按每个职业实际消费计划的全部
  need/variant/component 配置首日家庭库存，并配置首日建筑投入安全垫，
  以及建设桥接库存；后续投入由同步放大的产业链供应，避免预装过量库存压低上游需求。自然资源储量
  仍是量级分配的约束，不凭空扩充。连一人最低需求都

  建筑数量不再统一乘人口倍率。生成器以主食、蛋白、果蔬和衣着需求为最终需求，迭代加入每座
  建筑的真实投入形成上游需求，同商品生产者按现有供给权重分摊，并以本地 extract 储量的 365 日
  跑道或 capacity 容量封顶。无当前需求但资源合法的石器产业只保留一组，避免大批建筑因过量生产
  连续亏损后把本期岗位降为零。
  无法覆盖的地块不生成测试聚落，避免必然停工和死亡。生成顺序固定为建筑 owner-lot → catalog
  岗位汇总 → cohort；每个有人口地块优先放置一个商栈提供真实 merchant 岗位。所有 cohort
  获得 30 日 `survival_household` 生存金，业主追加两周期最低有效输入成本，商人追加本地产出目标库存金。
  就业人口始终受真实建筑岗位约束；初始就业为零，由原生图
  在后续周期结算。该 fixture 仅用于开发测试，不能作为正式历史人口来源。

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
份额和账本只由 C++ 修改。目录生成时 fixed/adaptive role 的参考工资均以职业默认生活成本为
下限，并按默认商人收购价、80% 售出率校准足以覆盖投入、工资、业主生活成本和目标利润的产量。目录审计遍历全部建筑并另限制生产原料成本
不超过默认商人收购收入的 60%、工具维护不超过 `100 GOODS_SCALE/岗位/日`，且工业总投入物量不超过
总产出物量的三倍，避免用异常放大的产量掩盖过高投入；运行时 `adaptive` 工资再使用
当地生活成本与岗位合同工资 EMA。同一 owner 在产品销售后按可用现金比例支付。销售后超过目标业主利润的
25% 形成奖金池。实际利润率（投入、基础工资、业主生活成本减自产生活抵扣）连续三周期不高于 -25% 后转为亏损停产；该判定不再依赖未包含业主生活成本的 `last_operating_cost`，因此纯自营工坊也会进入同一生命周期。停产不分配岗位、不采购、
不生产、不贡献企业需求，反事实利润连续两周期达到 +10% 且业主资金充足后恢复。生产后按采购
意图更新稀疏企业需求，并按真实居民/企业/建设出库更新实际出库 EMA、供给和成本锚，同时更新
稀疏 `(cell, profession)` 劳动市场信号，
供下一周期 Price V4 使用。
`building_cell_snapshot` 用 `owner_capacity` 表示完整物理槽位；活跃企业的 `owner_required`
等于该容量，只有亏损停产或不可用建筑才为 0。`filled_owner` 表示实际到岗，`owner_openings`
表示可从失业池补充的真实空缺。employee required 仍按本期计划利用率缩放。
UI 不得使用 `building count - filled_owner` 作为招聘空缺。
`building_commit` 每跨过 30 日边界运行一次内生资本评估。就业先填已有岗位；只有 owner 已满、
达到建筑目标利润率、利用率至少 75%、需求压力至少 12.5% 且缺口足以吸收半座日产能的 industrial
建筑才可新增一座。出资者人均储蓄必须覆盖本地现价建材和 30 日生活储备，目标收入还须比来源
收入高 12.5%；转职人口携带储蓄并复用 BUILD 的商人付款与商品 sink。collector/service 禁止
价格驱动自动扩张，每地块每次评估最多一座。
ACTIVE 企业还按上一周期售罄率与 `supply_price_elasticity_q16` 调整计划利用率；丢弃率不超过
1% 时按舍入噪声处理，家庭可用库存不超过 1 个 goods 子单位且短缺率至少 12.5% 时主动恢复，真实未成交只缩减下一周期 employee 岗位、
采购和产量，不把仍在经营的 owner 转为失业。耐储商品保留 1/32 探测下限，易腐/周期流商品保留 1/6；生存食物组还按同一业主人口的饥饿阈值自留需求计算动态下限并取较高值。生产者最低生存自留只在
该业主实际生产的单组分食物/寒冷衣物之间重新归一化，剩余产出仍进入全体家庭公平清算。Price V4 上涨使用默认价/成本锚的加法步长；
下跌使用当前价格作为步长基准，库存堆积时仍允许跌破成本清仓，但高成本锚不会放大负向跳水。
生产投入预留按互补配方的共同可执行比例缩放；任一投入缺失时不会继续锁住其他投入。非生存加工若消耗生存食物，则家庭生存清算优先，企业只使用剩余量。生产者托底只覆盖正常目标库存尚未填满的部分，超目标余量进入 discard，不再无条件发行货币入库。
`survival_required` 统一使用 `survival_household` 基础量、冻结人口/环境和民族修正，不读取财富或
价格 composite；普通消费仍使用财富/价格弹性，但生存品下单、自留和死亡共享同一冻结下限。
`consume_local_resources` 的资源边分为 `extract` 与 `capacity`：前者按本地储量限产并发布负 delta，
后者只限制建筑数量/产能而不扣减储量。农场以旱作耕地、水田或种植园容量生产 crop goods，
不再生成小麦/玉米等自然资源。负 pending delta 会立即压低下一经济周期的有效可采储量以防超采。
自然资源储量单位不与 goods 单位作 1:1 映射；extract 效率由各 BuildingProfile 的资源投入和
总输出共同定义，当前目录按采集方式与技术分为 `2:1` 至 `25:1`，同资源的后期矿井通常高于
早期开采点，蒸汽煤铁矿约为 `12:1`。多副产品按各输出数量之和计算；生成器在产量校准后重算
extract 扣减，内容审计复核效率范围。新地图 bootstrap 另以 ResourceProfile 的
`init_reserve_scale` 放大初值：农业 capacity 为 `1×`、林木为 `4×`、其他可再生资源通常为 `2×`、
地质/不可再生资源为 `8×`。林木另只在适生度最高的 30% 陆地保证至少 30,000 省域储量，
并使用承载量增长而非可能产生负净增长的线性衰减。有限地图上的关键矿产只在最适生的
0.5% habitat 保证最低矿床，避免连续地质场把整种资源截断为零；旱地、牧场在最适生 60%、
水田和种植园在最适生 20% 保证与最大建筑配方相匹配的承载下限。海鱼在沿海陆格与海洋水格的
联合 habitat 中保留约 72% 的适生格，温度、海域深浅、洋流、上升流、河口营养与连续噪声共同
决定丰度，不再全海域使用同一最低储量；其理想承载量为 500,000。
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
PKEC save，restore 后在下一次成功生产前显示为未知。

## 现代内容目录

- `tools/supply-chain-explorer/index.html` 是只读的设计时经济数值工作台。它直接扫描当前
  `BuildingProfile`、`GoodProfile`、`ProfessionProfile`、`NeedProfile` 与
  `ConsumptionPlanProfile`，在默认价格、财富/环境/族群系数为 1 的 reference scenario 下预计算
  建筑投入/承接收入/工资/业主生活费/盈亏平衡售出率，以及由建筑岗位人口形成的居民消费和逐物资
  供需缺口。它复用 catalog 的 need→variant→component 与投入候选效率语义，不读取 CSV、不写资源、
  不参与 PKEC、catalog hash 或模拟权威；动态资金、库存、价格、自留与托底结果仍只能由 native runtime
  或 Inspector/录制数据验证。
- 现代基线仍由 `tools/codegen/gen_modern_economy_content.ps1` 生成；脚本支持只读 `-Check`，以及
  只读写 profession/need/plan 的 `-Scope Consumption`。当前全目录为 120 goods、260
  production-method buildings、33 professions、17 needs 和 10 consumption plans。消费重平衡不改
  stable-ID 表或 PKEC v14 字节布局，但会改变 catalog hash，旧 hash 存档按现有 mismatch 路径拒绝。
- `GoodProfile` 额外编译 category、可执行的 `tech.*` `technology_tags`、`stock/cycle_flow` 与金银发行面值；其他标签命名空间仍只作元数据。
- `BuildingProfile` 必须是 collector 或 industrial，owner slots 固定为 1；30 个注册资源全部有
  collector。merchant 业主例外覆盖所有严格匹配真实矿藏的纯金银 collector。
- 30 种资源受 `land/marine_water/freshwater/coastal_land/coastal_or_marine` habitat 门控；
  海鱼储量可存在于沿海陆格和海洋水格，二者各自属于所在 cell；河口及近岸营养只影响初始化
  适生度，不改变资源所有权。淡水/淡水鱼不再是
  DataCore 经济资源。所有建筑资源边都必须为 `local`，native 只检查并扣减建筑本格储量，
  不存在邻域采集。
  矿产初值叠加资源局部斑块、
  同族地质省与矿带。栽培作物只存在于 goods，不进入 DataCore resource slots。
- 黄金/白银面值发行和普通可储存余货的 20% 托底发行是生产运行时的两类内生货币发行来源；电力是唯一 cycle-flow，utility prepass
  同周期供给，余量在周期边界清零，并且在家庭公用事业结算完成前不进入家庭能源需求。
- 软件、数字服务、AI 模型、轨道科研、遥测、卫星、深空探测与聚变燃料链已从目录删除；战略矿产
  保留内部 stable ID，并新增 `nuclear_fuel` 加工，核电与同位素反应堆不直接消耗战略矿物材料。
## 2026-07-18 balance contract

- Runtime authority remains `NativeEconomyRuntime`; profiles and this module are
  configuration/catalog inputs only.
- Owner livelihood participates in expected viability and output cost anchors.
  The cash buffer is capped at half of current owner-cohort cash, never blocks
  employee base payroll, and does not mint or transfer money.
- Merchant inventory horizons and targets are not reduced. Bid strength rises
  with the frozen target gap, and weighted procurement is capped and
  redistributed so unused priority budget reaches other real gaps.
- Stone-Age household weaving and knapping use local-demand-sized batches.
- CSV recorder schema v9 adds viability and natural/artificial resource-flow
  diagnostics without adding save-state authority.
## 2026-07-20 v14 override

This section is superseded by the PKEC v19 contract. Price-driven endogenous
investment reviews constructible industrial types only. Collector capacity is
created by explicit/resource policy and is bounded before employment by the
resource physically present; service capacity follows population/trade
topology policy. Bullion collectors therefore cannot expand from price alone.
Service buildings remain excluded.

Investment V5 leaves owner vacancies to the employment pass. Every cohort with
cash above its 30-day household reserve may sponsor construction, including the
target owner profession and merchant cohorts with more than one person.
Projected owner income must exceed current per-capita income; the relative gain
is sampled as a deterministic fixed-point probability. A winning sponsor moves
to the configured owner profession only when it is not already there.
Installed capacity remains a score input but is no longer an approval gate.
Profitable entry can proceed in an existing local market when sell-through,
discard, target margin, owner livelihood, payback, sponsor capital, relative
income and probability checks all pass.
Primitive collectors with no construction recipe participate with zero
construction cost, but retain the existing operating-capital, owner-livelihood,
profitability, payback, probability, and bullion gates.

Default merchant inventory coverage is 60 days before applying each good's
ratio. Procurement, trade, and bootstrap merchant funding retain that full
derived target. Price V4 instead derives its pricing inventory target from at most one
five-day settlement period, so a balanced current flow is not priced as a
60-day shortage. No parallel inventory state is introduced.

Catalog `min_price` and `max_price` remain legacy reference metadata. Normal
settlement, cost-anchor smoothing, trade quotes, bootstrap, and restore use only
the positive `int32` numeric guards `[1, INT32_MAX]`. Per-day rise/fall limits
remain the normal volatility control, and the producer cost anchor remains a
dynamic soft floor when active supply confirms the cost signal.

Production utilization uses household demand plus sparse business demand.
Business-only tools and intermediates recover from the industrial probe floor
when desired downstream inputs exceed realized withdrawals and available stock.
Realized owner-lot margin deducts the filled owners' minimum livelihood for the
period in addition to inputs and base wages; this livelihood test does not add a
cash transfer or a new ledger account.

The test-economy bootstrap uses local visible reserve abundance and a 3650-day
static extraction horizon to size collectors, then places industry only where
that cell exposes the required upstream outputs. This is deterministic bootstrap
configuration and does not move runtime building authority out of C++.

Bootstrap capacity keeps the cell-local closed-chain path as its first choice.
If local pruning would erase every previously construction-complete connected
trade component, it falls back to aggregate food, clothing, and mandatory-input
coverage inside each component and distributes carrying population
deterministically across its retained production cells. The fallback never
borrows across disconnected land components and still rejects missing hard-input
paths; reports expose `regional_capacity_fallback` and
`regional_capacity_fallback_cells`.

The 2026-07-21 selected-cell calibration keeps full owner self-retention but
raises `timber_collector` logs from 1808 to 5424 per day and Stone-Age hunting
outputs from `3728/45/23` to `4846/59/30`. Test bootstrap starts one knapping
workshop per supported local chain instead of three, avoiding immediate artisan
overcapacity before endogenous investment has observed demand.

Business demand is split into desired, funded, and unfunded quantities. Desired
demand remains visible when an owner is poor, while funded demand alone controls
real purchases and production. Working capital is allocated across each owner's
building portfolio by deterministic economic priority. Domestic trade consumes
sparse market/building signals, protects five days plus 50 percent target stock,
fills to 50 percent target, and prioritizes signals approaching the 15-day first
dispatch target.

The bounded trade planner rotates its deterministic active-signal scan origin by
simulation day. Within each country/good group it prioritizes never-attempted
destinations, then attempted-but-unserved destinations, then destinations that
already received a first dispatch. Committed diagnostics recompute current
deadline misses from all live signal clocks rather than from only the planner
slice that happened to run that day.

## PKEC v19 rolling settlement (current)

Production uses five stable daily buckets: cell `c` settles when
`day % 5 == c % 5`, always with `dt=5`. Each populated cell therefore settles
exactly every five days and committed state age is at most four days. The due
bucket completes and publishes behind the same-day barrier through bounded
native continuation calls. A real-frame pulse may execute multiple consecutive
continuations within `sim_frame_budget_ms`; one call still consumes at most one
building, market, or structural range. Workload-auto cadence and global
`WAIT_COMMIT` are not production paths. Trade arrival remains daily.

Current saves are PKEC v19. They persist per-cell settlement day/generation,
dirty generations, and each building group's pending recovery result/cooldown.
Restore accepts v18 with deterministic `pending=NONE, cooldown=0`; v2-v17 are
rejected as legacy. Older v14/v13 migration wording above is historical.

The native hot path caches the frozen demand basis once per due cell and shares
it between building retention and household clearing. Building-cell cache rows
are prepared in deterministic worker ranges and are neither save nor hash
authority. Reports expose `prepare_ms`, `audit_ms`, `watermark_ms`, and
`building_investment_ms` for rolling-stall diagnosis.

Building plan now aggregates owner survival floors in linear cell-local passes;
market-signal scratch storage follows each cell's sparse signal CSR instead of
the full catalog. Investment uses transient `(cell,type)` and `(cell,resource)`
indexes and advances through `building_commit_phase` cell continuations.
Reports and recorder summaries expose `building_investment_probability_skips`;
`building_owner_mobility` is emitted only for an actual construction sponsor
profession change.

Building production may partition one existing due-cell range through the native
WorkerThreadPool while `cell_to_market[cell] == cell` proves disjoint ownership.
Workers write only cell-local authoritative lanes and emit one `ProductionResult`
per cell. Native merges diagnostics, retained output, cashflows, and traces in
cursor order; the scalar fallback uses the same body and merge. GDScript remains
the catalog/profile/report shell and gains no economy authority. Reports expose
`building_production_worker_tasks` and `building_production_merge_ms`, with merge
time included in `building_production_ms`. There is no bridge, save-schema,
state-hash, DataCore-slot, stage, or cadence change.

2026-07-20 remediation keeps the same authority and cadence. Rolling employment
reports replace one cell's cached current-epoch contribution atomically, so a
non-due structural reconciliation cannot make unemployment negative. Investment
aggregates actual offered supply across every `(cell,good)`, includes owner livelihood
in operating cost, compares the remaining demand deficit with input coverage, and reports
explicit rejection reasons. Loss-suspended groups release every owner/employee; an
approved recovery probe rehires only its scaled probe capacity. CSV schema v12 adds resource flow direction,
procurement opportunity/allocation, in-kind livelihood coverage, and unresolved
trade-rejection buckets. These remain derived debug state outside PKEC and replay
hash. High discard accelerates the existing utilization response when no active
shortage recovery is required, while preserving shortage recovery and the
survival/probe floor.

CSV schema v13 adds `building_investment_probability_skips` to distinguish a
cash-qualified cohort losing its deterministic investment roll from capital,
material, resource, and profitability rejection. PKEC v16 historically added persisted
aggregate merchant debt, recovery state, failed reviews, and in-kind livelihood value.

CSV schema v14 adds ACTIVE owner-job mobility diagnostics. After ordinary
unemployed hiring, an ACTIVE non-service vacancy may attract one same-ethnicity
owner from an ACTIVE non-service group with at least one owner only when projected owner income is
higher. Targets sort by income descending and sources ascending; the relative
income gain drives a stateless `seed/day/cell/target_group/source_group` roll.
Each group can participate in one successful move per five-day period. Same-profession
movement changes group fill only; cross-profession movement reuses proportional
cohort migration. The last local merchant, SUSPENDED, service, unavailable, and
different-ethnicity groups are excluded. This adds no construction, capital flow,
stage, DataCore slot, or GDScript authority; v16 state and hash fields remain native.

The 2026-07-21 native correction separates the full-health
`survival_production_target_q16` from the starvation threshold. Household-consumed
retained output offsets source-building owner livelihood at frozen retail value without
creating cash. Household settlement is the single input-working-capital protection point;
production keeps only the uncovered wage reserve. Suspended owners move through the
existing unemployed-pool hiring path when an active non-service owner vacancy exists.
Investment uses actual offered-supply deficits, persistent merchant inventory-target gaps,
and input stock/supply coverage, not installed recipe capacity. These changes remain inside `NativeEconomyRuntime`; no
GDScript authority, save schema, DataCore slot, or cadence was added.

The 2026-07-22 lifecycle correction keeps service buildings outside producer profit states.
Every suspended owner moves into the existing unemployed pool; an approved recovery probe
hires again through the normal path. Owner-occupied no-production cycles can suspend a
blocked producer, while the installed group publishes a bounded 1/6 or 1/32 unfunded
upstream probe. Permanent liquidation reviews advance only when inputs, resources, and
financing can execute that probe but its expected margin remains below restart; temporary
blockage resets the failed-review streak. Probe capacity and liquidation eligibility are
transient native lanes outside PKEC and replay hash.

## 2026-07-23 renewable-harvest and fixture-employment correction

The optional test-economy bootstrap no longer expands renewable extractors from a
one-year reserve runway. Ecological resources use
`min(local_reserve, ideal_capacity / 8) * ecology_growth_rate *
resource_safe_harvest_q16` as their daily safe yield, divided by the recipe's
planned utilization and per-building extraction. Non-renewable extractors retain
the 3650-day bootstrap horizon. Scaling preserves the capacity-balanced base
owner-lots as an employment floor; only a physical resource cap may trim below
that proportional count. After demand/input rebalancing and merchant-post
placement, normal resource-tiered population is capped at generated job capacity
divided by the 95 percent employment target. Explicit 10x/100x/1000x fixtures
remain synthetic load tests.

The safe-yield calculation is bootstrap-only. Runtime production continues to
consume the resource physically present, and endogenous investment has no
reserve, safe-yield, or deposit-life veto. Overinvestment is therefore expressed
through resource shortage, lower realized capacity, profit, suspension, and
possible later liquidation rather than an approval hard cap. No authority,
DataCore slot, scheduler stage, save field, or hash field is introduced.

## 2026-07-23 portfolio investment and partial liquidation

The native `endogenous_owner_portfolio_v7` review keeps at most four unique
types per cell. It derives aggregate willingness from disposable-income
improvement, shares population/capital/credit/material/gap budgets, fills 25
percent of verified marginal gaps, and submits one BUILD count per type.
Multi-type portfolios cap a type at 50 percent of new owner slots. Recovery
liquidation retires only confirmed excess capacity and at most 25 percent of a
group per review, with proportional bad debt. PKEC v17 persists the four policy
controls and CSV v20 exposes the portfolio and liquidation diagnostics.

## 2026-07-23 lifecycle and investment-capacity correction

Producer lifecycle classification now advances `severe_loss_cycles` only from
an actual settled production cycle whose realized margin crosses the configured
loss threshold. Missing labor, inputs, resources, or working capital is an
execution blockage: the group stays active/idle, retains its labor claim and
restart intent, and does not enter loss liquidation merely because settlement
was zero.

`endogenous_owner_portfolio_v8` subtracts both unused installed output capacity
and aggregate pending-construction output from each marginal-good deficit before
candidate scoring. An established type may start at most 10 percent of its
installed count in one review (rounded up); a new type seeds at one building.
A non-merchant cohort must improve projected disposable income by at least
50 percent Q16 before changing into the merchant profession. These are bounded
integer calculations over the existing fixed-width portfolio.

The test-economy bootstrap creates exactly one merchant post per populated cell
instead of multiplying market infrastructure by population scale. Runtime
employment retains only the final merchant invariant; surplus merchants may
move through the normal aggregate profession/owner-job paths. PKEC v19 persists
the three new deterministic policy controls and explicitly rejects v17.
