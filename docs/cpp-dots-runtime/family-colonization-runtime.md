# 家族远程开拓与领土扩张运行时

## 权威边界

玩家只通过 `PlayerController` 的 `family.colonization.start/cancel` 提交意图。
`NativeEconomyRuntime` 拥有家族开拓队、冻结路线和在途人口载荷；
`NativeCountryRuntime` 只拥有领土；`EffectRuntime` 负责把抵达结算编排成
Country priority 255 与 Economy priority 260 的同一原生事务。UI 和 facade
均不直接写任何领域状态。

```text
ColonizationPlannerPanel
  -> PlayerController allowlist
  -> EconomyFacade
  -> FamilyExpeditionStore (PKEC)
  -> due min-heap
  -> Effect transaction (PKEF)
       -> CLAIM_UNOWNED_TERRITORY (PKCN)
       -> SETTLE_FAMILY_EXPEDITION (PKEC)
```

## 路线与报价

报价直接消费经济运行时现有 packed 六邻接、逐格 `passable` 与 `enter_cost`。
目标查询只执行一次反向整数 Dijkstra，然后遍历本国领土 cell CSR 与
cell-family CSR；不会扫描全体家族。距离、parent 和 heap scratch 长期复用，
generation stamp 避免每次清空全图数组，单次搜索最多扩展 8192 格。

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
循环。落地和返程只把同一载荷合并回真实 cohort，不生成现金、物资、建筑或
人口。目标被抢时完整路线返程；玩家取消按当前日期推导已行进成本；返程写回
原源地且不要求源地仍属原国家。

## 调度与事务

活动目标索引以 `(country_handle,target_cell)` 哈希 O(1) 判重。没有到期项时，
日调度只检查最小堆顶；进度由日期计算，不逐日扫描队伍。抵达时若目标已非无主，
直接切换 `RETURNING`。否则 Effect 提交一笔内置事务：Country 只接受
`owner == neutral` 的 `CLAIM_UNOWNED_TERRITORY`，Economy 只接受匹配 expedition
句柄与幂等键的 `SETTLE_FAMILY_EXPEDITION`。Country 拒绝时载荷不消费并返程；
成功时两域 ACK 完整后才对外发布。

事件回执为 `STARTED`、`CANCELLED_RETURNING`、`TARGET_LOST_RETURNING`、
`CLAIMED`、`RETURNED`。UI 在日期边界消费增量回执，不轮询或每日重建列表。

## 玩家 UI

目标地块入口与家族详情入口共用 `ColonizationPlannerPanel`。面板使用既有暗色
玻璃、羊皮纸和黄铜 token，显示源分支、最大人口、职业构成、成本、ETA 与明确
禁用原因；默认人数为 1。家族入口进入地图选点模式，Esc/右键退出。
`ColonizationRouteLayer` 是单个轻量 `Node2D`，用地图坐标绘制黄铜路线和日期推导
的进度标记，不创建逐格 Control，也不逐帧重建节点。540×600 的面板在
1280×720 安全区内无裁切。

## 存档与诊断

当前严格版本为 PKCN v11、PKEC v35；PKEF 当前为 v9。科技目录、研究信号、Effect
recipe、Trigger 定义或内容绑定摘要变化时，PKCN 以 `catalog_hash_mismatch` 拒绝旧存档。
完整恢复必须先恢复 PKCN，再恢复 PKEF 与 PKEC，使 PKEC 能交叉验证所有 `SETTLING`
事务。恢复后重建到期堆和活动目标索引。

`get_economy_report()` 暴露活动队数、到期堆大小、在途人口、路线查询、载荷拆分
和跨域提交耗时。核心回归在 `tests/family_colonization_runtime_test.gd`，覆盖冻结
路线、revision 重验、真实人口托管、O(1) 判重、进度返程、回执及 PKEC v35
中途恢复。

