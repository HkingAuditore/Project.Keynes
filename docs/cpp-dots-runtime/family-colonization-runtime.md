# 家族远程开拓与领土扩张运行时

## 权威边界

玩家只通过 `PlayerController` 的 `family.colonization.start/cancel` 提交意图。
`NativeEconomyRuntime` 拥有家族开拓队、冻结路线和在途人口载荷；
`NativeCountryRuntime` 只拥有领土；`EffectRuntime` 负责把抵达结算编排成
原生事务。无主目标仍是 Country priority 255 与 Economy priority 260 的双域
事务；本国目标只发 Economy `SETTLE_FAMILY_EXPEDITION`。UI 和 facade
均不直接写任何领域状态。

```text
ColonizationPlannerPanel
  -> PlayerController allowlist
  -> EconomyFacade
  -> FamilyExpeditionStore (PKEC)
  -> due min-heap
  -> Effect transaction (PKEF)
       -> 无主: CLAIM_UNOWNED_TERRITORY (PKCN) + SETTLE_FAMILY_EXPEDITION (PKEC)
       -> 本国: SETTLE_FAMILY_EXPEDITION (PKEC)
```

## 路线与报价

`start/cancel` 在空闲边界立即占用目标。开工包已完整时同一次调用抽离守恒人口与源地货物进入 `OUTBOUND`；绿地 `N >= 3` 且开工包不完整则写入 `EXPEDITION_PREPARING`，**不抽人、不抽货**，人留在源地继续生产缺货。冻结周期内改为写入 `_pending_commands`，由下一轮 `LEDGER_APPLY` 再占用或抽离。报价仍是只读预览。排队与筹备都占用 `(country,target)`，避免同一目标被点两次。若结算时人口不足、目标易主或路线失效，命令被拒绝或筹备被释放并写回执，不让经济 fatal。
报价直接消费经济运行时现有 packed 六邻接、逐格陆地 `passable`/`enter_cost`，以及同一套
水运门户 CSR。合法目标是当前可见、可通行的无主或本国陆地，且 `source != target`；外国格
与水体格返回 `colonization_target_invalid`，Country claim 仍拒绝 `_is_water`。报价字典带
`kind`：`colonize`（无主）或 `relocate`（本国）。目标查询只执行一次反向整数 Dijkstra，
然后遍历本国领土 cell CSR 与 cell-family CSR；不会扫描全体家族。距离、parent 和 heap
scratch 长期复用，generation stamp 避免每次清空全图数组，单次搜索最多扩展 8192 格。
本家族已在目标有成员时允许加强该分支；否则新分支受 `_family_max_per_cell`
（默认 8，一城只有几家）限制。

陆地路段必须可见，并且只经过本国或无主地块。海/湖走廊按开拓国 live 科技能力跳跃，
水体格不要求可见、不进入搜索堆；还原路线时再展开走廊格子供 UI 与累计成本使用。进入下一格的
成本计入总成本，默认速度为每日至少一点成本。河运把两端 `has_river` 的陆地边成本减半。
报价 token 绑定国家、家族、
源地、目标、拓扑 generation、国家 generation、视野 hash、路线 hash 与
目标侧开工包 identity。确认时 revision 改变会重算；路线 hash 相同可接受，
否则返回 `colonization_requote_required`。目标资源/科技变化返回
`colonization_kit_requote_required`。出发后路线、许可与开工建筑计划冻结，
抵达前不重寻路。

## 守恒人口托管

`FamilyExpeditionStore` 是 generation-safe SoA，路线、累计成本、cohort 载荷和
重要人物句柄使用扁平 CSR。派遣人数满足 `1 <= population < branch_population`。
`PREPARING` 把意图人数记在 `population` 标量上，payload/cargo 保持为空，人不进开拓队 escrow。
抽取先按稳定顺序消费失业成员，不足部分按非失业 cohort 比例分配，最大余数
以 `(profession, ethnicity, cohort_handle)` 决定；不得抽走源地最后一个活着的
商人。商人保护若裁掉已分配名额，必须立即从剩余非商人成员回填，使实际抽离人数
仍等于命令人数；回填后仍不足则在改账本之前拒绝并写回执，不得把
`FamilyExpeditionStore.population` 留在请求人数、载荷 `people` 却更少。在途人口
审计与家族人口合计一律加总载荷 `people`，不信任可能过期的标量。抽离中途失败
必须把已扣的源地 cohort / 成员边 / 人物句柄滚回去，不能只 release 开拓队。
空闲出发会立即 `ensure_merchant_invariant` 并重建商人 CSR：抽离写入的
`_structural_touched_cells` 会在下一轮 `start_epoch` 被清空，不能再等到
`STRUCTURAL_COMMIT` 才补商人。开工包落地按建筑转职时同样保留最后一名本地商人；
`rebuild_merchant_ranges` 若发现有人口格缺少活商人，先走同一套兜底修复，
只有修复失败才 fatal `merchant_invariant_broken:cell=`。所有比例运算复用原生
`mul_div_sat`，保留 population、funds、收入/支出 EMA、税与补贴归因、满意度、
残差、family cash claim 和就业归因；重要人物按 seed、expedition stable ID 与
person stable ID 确定性随行。

在途载荷计入经济人口、资金、货物和家族审计，但不参与本地市场、就业或日常人口
循环。空闲边界出发或返程会把 cohort 资金和开工包货物搬进/搬出开拓队 escrow。
下一轮 epoch 若仍复用上一收盘 totals 却 live 刷新 escrow，会把同一笔钱或货算两次或漏掉。
因此出发、落地、取消和返程会同时强制下一轮 opening/closing 全量审计；即使
漏设该标志，只要 live 开拓队人口、`expedition_funds` 或 `expedition_goods` 与上一收盘不一致，
opening 也会自动改走全量 scan。落地和返程只把同一载荷合并回真实 cohort / 源地市场，
不生成现金、物资、建筑或人口；绿地到达额外消耗 construction cargo 并插入已冻结的
家族建筑计划，审计记入 `construction_goods_consumed`。冻结周期内落地只把新建筑组
追加到 `_buildings` 尾部，不得调用 `rebuild_building_role_storage` /
`rebuild_market_signals`：epoch 初冻结的 group 下标、生产 reserve 和市场信号 CSR
按 `(cell, good)` 排序，中途插入中间格会平移后续信号，活地图上货物守恒失败并把
日历钉在 `economy_day_barrier`。拓扑重建推迟到同轮 `BUILDING_COMMIT`（与
`commit_ready_construction` 同一边界）；空闲边界落地仍立即重建，供 Inspector
与下一轮工作集看见新组。冻结周期内落地只 `audit_touch` 目标 lane，不得重建增量审计影子，否则会丢掉
`+people / -transit` 差额。每个 epoch 开端会从当前 live 状态重拍增量影子；全量收盘
把在途开拓队人口计入 closing population，把开拓队资金记入
`AuditTotals.expedition_funds` 后再并入 `escrow_cash`，并把开拓队货物记入
`AuditTotals.expedition_goods` 后再并入 `goods_stock`。目标被抢时完整路线返程并把货物退回源地市场；玩家取消按当前日期推导已行进成本；返程写回
原源地且不要求源地仍属原国家。SETTLING 一旦消耗落成，不可取消。

## 调度与事务

活动目标索引以 `(country_handle,target_cell)` 哈希 O(1) 判重。没有到期项时，
日调度只检查最小堆顶；进度由日期计算，不逐日扫描队伍。抵达时按当时归属三分叉：
外国或丢失切换 `RETURNING`；无主则 enqueue CLAIM+SETTLE；本国则只 enqueue
SETTLE。Country 只接受 `owner == neutral` 的 `CLAIM_UNOWNED_TERRITORY`，
Economy 只接受匹配 expedition 句柄与幂等键的 `SETTLE_FAMILY_EXPEDITION`。
CLAIM 路径在 Country priority 255 ACK 之后，空闲经济周期可在 `EPOCH_BEGIN`
前立即落地；本国迁徙没有 Country 前置，Economy 可在同一切片消费 SETTLE。
空闲入口必须先 `process_due` 把到达队伍 enqueue，再 `dispatch_native_economy`：
到达当日的 SETTLE 在第一次 dispatch 时还不存在，若只在 `process_due` 之前派发，
本国迁徙会停在 `SETTLING`（面板「落地结算中」）直到下一次空闲周期。若冻结周期
已开始且阶段仍在 `BUILDING_PLAN` / `TRADE_SETTLE` / `LEDGER_APPLY`，SETTLE
追加进本轮 `_epoch_commands`，由本轮 `LEDGER_APPLY` 消费；更晚的阶段才进入
pending，等下一轮 epoch。`EPOCH_BEGIN` 预检不得把 expedition 句柄当成 cohort
句柄丢弃。若旧存档已经把 SETTLE 丢掉但仍停在 `SETTLING`，下一轮空闲周期会按
同一幂等键把未完成的 Effect 请求重新排入 pending。Country 拒绝时载荷不消费并
返程；无主开拓在两域 ACK 完整后才对外发布，本国迁徙在 Economy ACK 后发布。
PKEF v10 restore 接受旧的 2-command CLAIM+SETTLE 以及新的 1-command SETTLE。
SETTLE 的 `i32_1` 来自 Effect payload[3]（可选守恒 `population_reward`），不得改 payload[0]
的格子字，否则会破坏 CLAIM/SETTLE 的 PKEF 相等校验。`i32_1>0` 时落地 ACK 后走显式
`POPULATION_SOURCE` 账本，不凭空加人口。`family.population_reward` 的 `i32_0=-1`
把人数冻进家族标量，目标是合法 `FamilyCellInfluence` 句柄；创始家族 bootstrap 必须立即
重建 influence，不能等 4 个 epoch。

事件回执为 `STARTED`、`CANCELLED_RETURNING`、`TARGET_LOST_RETURNING`、
`CLAIMED`、`RELOCATED`、`RETURNED`。UI 在日期边界消费增量回执，不轮询或每日重建列表。

## 玩家 UI

目标地块入口与家族详情入口共用 `ColonizationPlannerPanel`。无主格显示开拓，
本国格显示迁徙。面板是 `PKDialog` 卡片选择器，每张可派遣卡只展示族名、家族人口和
特性/效果；特性芯片悬停显示机制说明，无行为偏好时效果行改用中文加成名。
源地编号、职业构成、路线成本和旅行日不进入默认文案，后两者仅留在
tooltip。同一家族多个可达源地合成一张卡，并自动选人口最多的源分支。
选中后人数默认填满可派遣上限。完整开工包时主按钮显示「派遣 N 人并安家」；
绿地开工包不完整时显示「开始筹备 N 人」，成功码 `colonization_preparing`，切到「在途」页显示「筹备中」与缺货行。
缺货行按 `kit_blocker` 逐条说明卡点，并同时给出口粮与建材两个分项百分比；行内 `Effect` 标签
`max_lines_visible` 为 4，2 行会把说明直接截掉。迁徙或部分桥接库存仍显示「派遣 N 人」，并用黄铜说明「基础物资不足，只携带当前可用物资」。物资不够不再禁用按钮。
冻结周期顶部仍用黄铜
提示结算中，确认按钮改为「排队派遣 N 人」并保持可点；点击后命令进入 pending，
提交完成后自动抽离人口与源地货物出发。取消同样可在结算中排队。若结算中暂时没有可列家族，
显示等待说明而不是「没有可派遣的家族」。守恒失败暂停后报价返回 `economy_paused`，
面板清空可点卡片并说明经济已暂停，不得把 `economy_not_available` 当成结算中的瞬时
busy。家族入口进入地图选点模式，Esc/右键退出。
报价 token 集合不变时不重建卡片树。`ColonizationRouteLayer` 是单个轻量 `Node2D`，
用地图坐标绘制黄铜路线和日期推导的进度标记，不创建逐格 Control，也不逐帧重建节点。
540×600 的面板在 1280×720 安全区内无裁切。

## 开工包

无主或本国空地（已提交建筑组 = 0 且无在建）携带完整开工包：口粮采集营、可选衣物链、
枯枝营（若资源允许）、早期商栈，以及 `max(1, travel_days) + 15` 日食品/衣物桥接。
食品桥接把主食、蛋白质和蔬果的候选合并为一个总食品池，任一食品候选都可以填充这份总量；
它们不再分别作为开拓或迁徙的出发门槛。衣物桥接仍按衣着 need 单独计算。
衣物桥接与口粮相同，按衣着 need 的 `base_qty_per_person` × 日数计（生存方案为每人每日 2 毫单位），
而不是每人每日 1 整件衣物。采集营 `tools` 类投入按 `max(旅行日+15, 开工包建筑数)` 记入 `EXPEDITION_CARGO_BUFFER`。
桥接食品按合并食品池的候选顺序从源地市场混装，衣着仍按衣着 need 的单组件 variant 顺序混装；工具先取 preferred good，
再按已编译输入候选顺序混装；开拓建材同样在每个 construction candidate group 内按效率折算后
混装。cargo 始终记录各具体物资的实际物理量，不允许跨食品池、衣着、输入组或建材组抵扣。普通 BUILD 与
投资仍要求单个候选独自满足一组，并按现有低成本规则选择，不启用开拓专用 split policy。
已有建筑或在建的目标只带桥接库存，不落成新建筑。`N < 3` 标记 `kit_partial`，
只带桥接。绿地 `N >= 3` **不允许带着空建筑列表出发**：库存不够就留在 `PREPARING`。

开工包规模由 `COLONIZATION_KIT_FOOD_COVERAGE_Q16` 封顶，不再把剩余业主槽全部填成采集营；
派遣人数上升不会让建材需求线性膨胀，也就不会把筹备拖成看不到头的囤积。

`PREPARING` 是**逐日囤积**，不是逐日重试。每个到期日 `advance_preparing_family_expedition`
必定重跑一次 `plan_colonization_kit`（不再用缺货库存哈希跳过，因为余量可能出现在上次并不缺的
物资上），然后 `reserve_preparing_family_expedition_cargo` 把当天买得起的差额从源地市场划入队伍
托管 cargo。规划把已托管量当作可用库存（`ColonizationReserveContext::reserved`），所以每条
`kit.cargo` 表示"必须持有的总量"，只搬差额；计划缩小时超额先退回源地市场。`prefer_reserved_candidates`
让已囤积的替代品排在候选前面，避免新到货的首选候选把已付出的货搁死。

托管不得吃掉源地自己的口粮：`ColonizationReserveContext::floor` 由
`colonization_source_survival_floor` 用同一套桥接规划器跑源地自身人口
`COLONIZATION_RESERVE_SOURCE_FLOOR_DAYS = 10` 天算出，规划与划账都只看
`max(0, 市场库存 - floor) + 已托管`。到期处理发生在市场结算之前，没有这条底线会把源地掏空。

齐套后 `launch_preparing_family_expedition` 只抽人口（cargo 已在托管里），并在此刻才写入
`kit_building_*`；抽人失败保留托管、次日重试。`abort_preparing_family_expedition`（取消、
目标易主、源地人口不足）必须先把托管 cargo 退回源地市场，否则取消筹备会凭空销毁货物。

`kit_partial` 的建材位只反映**最终**规划与原始意图的差距，不再被"历史上砍过一栋建筑"永久锁定；
`missing_good_ids` 同样只收录最后一次 `materials_fit` 的缺口，并与 `plan_construction_materials`
统一用 `good_market_available` 判定可得（先前用更窄的 `good_production_available`，会写出空清单）。
开工包的建材组走全库统一的时代分池（`primitive_construction` / `primitive_lashing` 等，
见 native-economy-runtime.md），所以源地缺某一种具体材料不再等于开不了工；
`kit_unbuildable` 只在整组候选都不可得时才会触发。
若某个建造组的全部候选在源地市场都不可得，规划置 `kit_unbuildable`，
`advance_preparing_family_expedition` 立即 abort 并写 `PREPARING_UNBUILDABLE` 回执、退还托管、
释放目标占用——这种缺口不会随时间消失，继续逐日囤积就是永久卡死。

规划复杂度仍是 `O(unlocked_types)`，禁止把 GDScript `StarterEconomyPlanner` 的 20 人穷举
搬进报价热路径，也不扫全图、不跑投资周期 I。
物资只从源地市场划走；`N < 3` 抽货失败仍可回执 `colonization_kit_materials_short`。
到达仍一次性插入冻结开工计划；若 BUFFER 里还有建材，落地当天对目标再 `plan_colonization_kit` 一次
（`ignore_existing=true`，用剩余业主槽封顶），用剩余建材补插。

## 存档与诊断

当前写出为 PKCN v11、PKEC v51；PKEF 当前为 v11。reader 只接受同版本。
v51 的 `EXPEDITION_PREPARING` 记录要求 `payload_count == 0` 且 `kit_count == 0`，
但 `cargo_count` **可以非零**——那是筹备期逐日囤积的托管货物，已计入在途货物守恒总量与
authoritative state hash。v42 曾要求 PREPARING 的 cargo 也为 0，该约束在 v51 解除。
科技目录、研究信号、Effect recipe、Trigger 定义或内容绑定摘要变化时，
PKCN 以 `catalog_hash_mismatch` 拒绝旧存档。完整恢复必须先恢复 PKCN 与 PKEF，再恢复 PKEC，
使 PKEC 能交叉验证所有 `SETTLING` 事务。恢复后重建到期堆和活动目标索引；筹备队保留保存时的
缺货 identity；revision 4 把不足组的全部候选纳入监听，并将食品缺口统一为合并食品池。
revision 5 起 identity 不再用于跳过重规划（每日必重规划），只用于让 UI 感知筹备进度变化，
因此把桥接需求/缺口与当前托管 cargo 一起混入。
`kit_missing_good_ids` 表示不足组的库存监听候选，而非每种物资都必须分别齐套。
筹备进度另由 `kit_bridge_required_units` / `kit_bridge_missing_units`（未被库存钳制的
原始桥接需求与剩余缺口）与 `kit_material_required_units` / `kit_material_missing_units`
（完整开工意图的建造需求，以及源地当前仍供不起的那部分）暴露，`kit_blocker` 再给出
`READY` / `BRIDGE` / `MATERIALS` / `NO_BUILDINGS` / `UNBUILDABLE` 之一说明真正卡在哪。
UI 的"已囤积 N%"必须按桥接 + 建材合计口径算：只看桥接会在建材还差一大截时显示 100%。
这五个值都是每次查询时只读重规划得到的派生量，不落存档，PKEC schema 不变。已有建筑的本国地块迁徙仍只携带桥接库存，不落成新建筑，也不额外抽取建材。
v36 在途队伍 cargo 为空，到达后不落成开工包。

`get_economy_report()` 暴露活动队数、到期堆大小、在途人口、路线查询、载荷拆分
和跨域提交耗时。核心回归在 `tests/family_colonization_runtime_test.gd`，覆盖冻结
路线、revision 重验、真实人口/货物托管、O(1) 判重、进度返程、回执、PKEC v42
中途恢复，零库存绿地 N=3 进入 PREPARING、人不离开源地、补库存后下一 idle 日 OUTBOUND，
砍过建筑的开工包在建材补足后仍必须能出发、建造组按 substitution category 接受替代建材、
结构性不可得触发 `PREPARING_UNBUILDABLE` abort 且不凭空增减货物，
绿地 N≥3 落成采集+商栈、返程退货、已开发格不落成，
冻结周期内排队的 `SETTLE_FAMILY_EXPEDITION` 能通过 epoch 预检并落地，
在更高序号格已有建筑时把开工包插入中间格不得打乱守恒，
冻结周期内报价仍可读，`start/cancel` 在 `economy_busy` 时改为 `colonization_queued` /
`colonization_cancel_queued` 并在下一轮 ledger 抽离或返程，
以及本国已有人口格的 SETTLE-only 迁徙、`source == target` 无报价和外国目标拒绝。
`player_controller_contract_test.gd` 覆盖开拓面板在结算中仍显示家族卡片，确认按钮可点并显示排队，以及同家族多源地合并为单卡、默认填满可派遣人数、完整开工包「安家」文案、不完整绿地「开始筹备」、物资不够不再锁按钮。
缺 `maximum_population` 的选中字典不得崩溃；`economy_paused` 必须显示暂停说明而不是保留旧卡。

