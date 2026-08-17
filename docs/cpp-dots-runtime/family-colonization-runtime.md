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

`start/cancel` 在空闲边界立即抽离守恒人口；冻结周期内改为写入 `_pending_commands`，
由下一轮 `LEDGER_APPLY` 再抽离。报价仍是只读预览。排队占用 `(country,target)`，
避免同一目标被点两次。若结算时人口不足或路线失效，命令被拒绝并写回执，不让经济 fatal。
报价直接消费经济运行时现有 packed 六邻接、逐格 `passable` 与 `enter_cost`。
合法目标是当前可见、可通行的无主或本国陆地，且 `source != target`；外国格返回
`colonization_target_invalid`。报价字典带 `kind`：`colonize`（无主）或
`relocate`（本国）。目标查询只执行一次反向整数 Dijkstra，然后遍历本国领土
cell CSR 与 cell-family CSR；不会扫描全体家族。距离、parent 和 heap scratch
长期复用，generation stamp 避免每次清空全图数组，单次搜索最多扩展 8192 格。
本家族已在目标有成员时允许加强该分支；否则新分支受 `_family_max_per_cell`
（默认 8，一城只有几家）限制。

路线必须全程可见、为可通行陆地，并且只经过本国或无主地块。进入下一格的
成本计入总成本，默认速度为每日至少一点成本。报价 token 绑定国家、家族、
源地、目标、拓扑 generation、国家 generation、视野 hash 与路线 hash。
确认时 revision 改变会重算；路线 hash 相同可接受，否则返回
`colonization_requote_required`。出发后路线与许可冻结，抵达前不重寻路。

## 守恒人口托管

`FamilyExpeditionStore` 是 generation-safe SoA，路线、累计成本、cohort 载荷和
重要人物句柄使用扁平 CSR。派遣人数满足 `1 <= population < branch_population`。
抽取先按稳定顺序消费失业成员，不足部分按非失业 cohort 比例分配，最大余数
以 `(profession, ethnicity, cohort_handle)` 决定。所有比例运算复用原生
`mul_div_sat`，保留 population、funds、收入/支出 EMA、税与补贴归因、满意度、
残差、family cash claim 和就业归因；重要人物按 seed、expedition stable ID 与
person stable ID 确定性随行。

在途载荷计入经济人口、资金和家族审计，但不参与本地市场、就业或日常人口
循环。空闲边界出发或返程会把 cohort 资金搬进/搬出开拓队 escrow。下一轮
epoch 若仍复用上一收盘 totals 却 live 刷新 escrow，会把同一笔钱算两次或漏掉。
因此出发、落地、取消和返程会同时强制下一轮 opening/closing 全量审计；即使
漏设该标志，只要 live 开拓队人口或 `expedition_funds` 与上一收盘不一致，
opening 也会自动改走全量 scan。落地和返程只把同一载荷合并回真实 cohort，不生成现金、物资、建筑或
人口。冻结周期内落地只 `audit_touch` 目标 lane，不得重建增量审计影子，否则会丢掉
`+people / -transit` 差额。每个 epoch 开端会从当前 live 状态重拍增量影子；全量收盘
把在途开拓队人口计入 closing population，并把开拓队资金单独记入
`AuditTotals.expedition_funds` 后再并入 `escrow_cash`。目标被抢时完整路线返程；玩家取消按当前日期推导已行进成本；返程写回
原源地且不要求源地仍属原国家。

## 调度与事务

活动目标索引以 `(country_handle,target_cell)` 哈希 O(1) 判重。没有到期项时，
日调度只检查最小堆顶；进度由日期计算，不逐日扫描队伍。抵达时按当时归属三分叉：
外国或丢失切换 `RETURNING`；无主则 enqueue CLAIM+SETTLE；本国则只 enqueue
SETTLE。Country 只接受 `owner == neutral` 的 `CLAIM_UNOWNED_TERRITORY`，
Economy 只接受匹配 expedition 句柄与幂等键的 `SETTLE_FAMILY_EXPEDITION`。
CLAIM 路径在 Country priority 255 ACK 之后，空闲经济周期可在 `EPOCH_BEGIN`
前立即落地；本国迁徙没有 Country 前置，Economy 可在同一切片消费 SETTLE。
若冻结周期已开始，SETTLE 进入 pending，由下一轮 epoch 的 `LEDGER_APPLY`
消费。`EPOCH_BEGIN` 预检不得把 expedition 句柄当成 cohort 句柄丢弃。若旧存档
已经把 SETTLE 丢掉但仍停在 `SETTLING`，下一轮空闲周期会按同一幂等键把未完成
的 Effect 请求重新排入 pending。Country 拒绝时载荷不消费并返程；无主开拓在
两域 ACK 完整后才对外发布，本国迁徙在 Economy ACK 后发布。PKEF v9 restore
接受旧的 2-command CLAIM+SETTLE 以及新的 1-command SETTLE。

事件回执为 `STARTED`、`CANCELLED_RETURNING`、`TARGET_LOST_RETURNING`、
`CLAIMED`、`RELOCATED`、`RETURNED`。UI 在日期边界消费增量回执，不轮询或每日重建列表。

## 玩家 UI

目标地块入口与家族详情入口共用 `ColonizationPlannerPanel`。无主格显示开拓，
本国格显示迁徙。面板是 `PKDialog` 卡片选择器，每张可派遣卡只展示族名、家族人口和
特性/效果；特性芯片悬停显示机制说明，无行为偏好时效果行改用中文加成名。
源地编号、职业构成、路线成本和旅行日不进入默认文案，后两者仅留在
tooltip。同一家族多个可达源地合成一张卡，并自动选人口最多的源分支。
选中后人数默认填满可派遣上限，主按钮显示「派遣 N 人」。冻结周期顶部仍用黄铜
提示结算中，确认按钮改为「排队派遣 N 人」并保持可点；点击后命令进入 pending，
提交完成后自动抽离人口出发。取消同样可在结算中排队。若结算中暂时没有可列家族，
显示等待说明而不是「没有可派遣的家族」。守恒失败暂停后报价返回 `economy_paused`，
面板清空可点卡片并说明经济已暂停，不得把 `economy_not_available` 当成结算中的瞬时
busy。家族入口进入地图选点模式，Esc/右键退出。
报价 token 集合不变时不重建卡片树。`ColonizationRouteLayer` 是单个轻量 `Node2D`，
用地图坐标绘制黄铜路线和日期推导的进度标记，不创建逐格 Control，也不逐帧重建节点。
540×600 的面板在 1280×720 安全区内无裁切。

## 存档与诊断

当前严格版本为 PKCN v11、PKEC v36；PKEF 当前为 v9。科技目录、研究信号、Effect
recipe、Trigger 定义或内容绑定摘要变化时，PKCN 以 `catalog_hash_mismatch` 拒绝旧存档。
完整恢复必须先恢复 PKCN，再恢复 PKEF 与 PKEC，使 PKEC 能交叉验证所有 `SETTLING`
事务。恢复后重建到期堆和活动目标索引。

`get_economy_report()` 暴露活动队数、到期堆大小、在途人口、路线查询、载荷拆分
和跨域提交耗时。核心回归在 `tests/family_colonization_runtime_test.gd`，覆盖冻结
路线、revision 重验、真实人口托管、O(1) 判重、进度返程、回执、PKEC v36
中途恢复，冻结周期内排队的 `SETTLE_FAMILY_EXPEDITION` 能通过 epoch 预检并落地，
冻结周期内报价仍可读，`start/cancel` 在 `economy_busy` 时改为 `colonization_queued` /
`colonization_cancel_queued` 并在下一轮 ledger 抽离或返程，
以及本国已有人口格的 SETTLE-only 迁徙、`source == target` 无报价和外国目标拒绝。
`player_controller_contract_test.gd` 覆盖开拓面板在结算中仍显示家族卡片，确认按钮可点并显示排队，以及同家族多源地合并为单卡、默认填满可派遣人数。
缺 `maximum_population` 的选中字典不得崩溃；`economy_paused` 必须显示暂停说明而不是保留旧卡。

