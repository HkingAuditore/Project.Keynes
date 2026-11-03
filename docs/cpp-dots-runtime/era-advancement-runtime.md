# 时代晋升（Era Advancement）与国家购买预算

> 状态：2026-11-01 设计稿 → 实现中。本文同时是多 agent 并行实现的**接口契约**；
> 实现与本文冲突时先改本文再改代码。

## 0. 目标（玩家需求）

1. 取消「研究时代里程碑科技才能升时代」。所有时代里程碑科技从玩家科技树/可研究清单/总览中
   移除，玩家不能研究它们；它们原本的效果改为「升级时代后获得的 buff」。
2. 升时代改为：点击屏幕上方时代 icon → 打开时代晋升面板，显示前提条件与成本。
   - 前提条件 4 选 2：
     a. 完成本时代 50% 科技（本时代 = 当前时代，统计 `era_id == 当前时代` 的研究科技，
        排除里程碑节点与 `app.*`；state 5 才算完成，开局科技计入）；
     b. 人口 ≥ 每时代阈值；
     c. 建筑数 ≥ 每时代阈值（已落成建筑单位数，`BuildingGroup.count` 之和）；
     d. 本时代完成的贸易次数 ≥ 每时代阈值（国内 + 跨国贸易订单，国家作为来源或目的地）。
   - 任意 2 项达成即可「开始晋升」。
   - 开始后，玩家需「收购」与地块数量相关的大量物资；物资种类与数量随时代不同。
     收购是持续过程，买到的物资进入国库；国库中对应物资全部达标后自动消耗并完成晋升。
   - 晋升过程可随时暂停 / 继续。
3. 国家购买预算：国库面板中一个滑条，玩家选择「每日把国库现金的百分之几用于国家购买」；
   国家购买 = 派遣储备（开拓筹备采购） + 升级时代收购 + 科技投入（科技值采购）。
   科技面板原来的科技采购滑条改为「国家购买预算中百分之多少投入科技购买」。
4. 晋升完成的演出要重点表现。

## 1. 权威与总体方案

不新建独立 Runtime。复用：

| 状态 | 权威 |
| --- | --- |
| 当前时代 | 仍由 `NativeCountryRuntime` 已完成的时代里程碑 bit 推导（`visual_era_index_for_slot`、`CountryFacade.current_era_index`、Ideology `unlocked_era_for`、年报 era 均不变） |
| 里程碑节点 | 保留为**内部时代令牌**（dense ID、Effect recipe、时代奖励池映射不变），玩家不可见、不可入队；由「时代晋升」以 `GRANT_TECHNOLOGY` 授予 |
| 晋升 buff | 里程碑节点新增显式 `modifier_terms`（永久 Country Modifier，走既有 TECH UNIQUE_SOURCE 激活链）+ 既有时代奖励三选一（里程碑完成 → `NOTIFY_ERA_REWARD`） |
| 国家购买政策（国库份额、科技份额） | `NativeEconomyRuntime`（经济命令写入、周期边界生效；玩家会话在 `player_view` 中持久并在读档后重推） |
| 时代收购目标（物资 + 需求量） | `NativeEconomyRuntime` 的 transient 目标表（经济命令写入；`player_view` 持久并重推） |
| 时代收购执行（市场 → 国库） | 经济新 pass `government_era_procurement`，复用 `GOOD_FROM_MARKET` 资产事务（同步与 Country worker 两路） |
| 物资消耗 + 授予时代令牌 | Country 新命令 `CONSUME_TREASURY_GOODS = 21` 与 `GRANT_TECHNOLOGY = 4` **同一批次原子提交** |
| 晋升状态机（未开始/收购中/暂停/完成中）、冻结地块数、本时代贸易计数基线 | 玩家会话 `EraAdvancementService`（GDScript，PlayerController 持有），持久于 `player_view` |
| 规则（阈值、物资、每地块数量、buff 文案） | 静态目录 `EraAdvancementCatalog`（GDScript） |

外国 AI：本轮仍沿用原生里程碑研究作为其时代推进（AI 不受玩家入队白名单约束）；记录为已知限制。

## 2. 原生接口（Native agent 实现）

### 2.0 原生实现现状（2026-11-01）

- Country：`COMMAND_CONSUME_TREASURY_GOODS = 21`（`COMMAND_OPCODE_MAX`），同步 staged batch
  （`stage_goods`，扣减同时扣除在途经济资产预留量）与 POD `country_core_apply_command case 21`
  都已实现；Host 入口 `enqueue_country_host_command_batch` 的 opcode 上限改为 `COMMAND_OPCODE_MAX`。
  transient 计数 `_country_treasury_goods_consumed_total` / `RuntimeCountryPodSnapshot::treasury_goods_consumed_total`
  不进 PKCN、`country_core_hash_business_state`、`country_core_first_business_difference`，
  也不进 worker 检查点载荷（读档 / handoff 归零）。
  `sample_economy_goods_audit` 与 `research_consumed_total()` 把它并入「Country 已消耗货物」，
  经济 VERIFY 无需新字段即保持 goods_err = 0。
- worker 路径 late-fold：当天若某 producer 提交了 21，则该 producer 的 21/4 包不做逐条 late-fold
  （逐条应用会让被拒的消耗与授予分离），而是保留到下一个 `plan_day` 整批原子校验。
- 经济：新文件 `economy_runtime_procurement.cpp`。政策 / 目标通过 mutex 收件箱
  （`ProcurementInbox`）任意线程写入，经济拥有线程在 `start_epoch` 冻结国家快照后、财政预留前
  `apply_pending_procurement_updates` + `freeze_epoch_procurement_budgets`；ACTIVE worker 无需
  抢经济边界。`research_procurement_policy_for` 在有政策时用 `research_daily` 覆盖日预算
  （研究采购、研究需求信号、财政研究保底三处）。派遣：`refresh_epoch_colonization_demand`
  预算被 `colonization_daily × epoch_days` 截断，筹备期实际国库采购受按日补充、上限 1 周期的额度约束
  （超额时 `colonization_procurement_budget_exhausted`，次日重试）。
- 时代收购 pass `run_government_era_procurement` 在 `GOVERNMENT_RESEARCH_PROCUREMENT` 阶段、
  研究采购完成后运行（slice 路径与 StageOps drain 路径都已接入），一次一笔 `GOOD_FROM_MARKET`，
  同步与 Country worker（`block_or_enqueue_country_worker_asset` + defer settlement）两路；
  Host 待决时以 `country_research_peer_results` 停泊。需求信号并入
  `epoch_procurement_demand_daily[_for_market]`；现金记 `NON_TAX_ERA_PROCUREMENT = 4`
  （`non_tax_outflow_kinds[4] = "era_procurement"`，PKEC schema 58 仍只持久前 4 槽，第 5 槽读档为 0）。
- `trade_orders_total`：每个派发的贸易订单（国内 + 跨国）对来源国、目的国（不同国时）各 +1，
  transient，按 epoch 国家槽位 + handle 盖章。
- 查询 `DCWorldExt.country_procurement_snapshot` 走 `committed_read`
  （`ReadQuery::COUNTRY_PROCUREMENT_SNAPSHOT`）；worker ACTIVE 首次读取可能返回 `economy_busy_retry`。
  快照立即反映尚未生效的请求（附加键 `policy_pending` / `era_pending` / `era_current_epoch_cash`）。
- 测试：`tests/era/era_procurement_runtime_test.gd`。

### 2.1 Country 命令 `CONSUME_TREASURY_GOODS = 21`

- 字段：`target_handle` = 国家，`aux` = good dense id，`value` = 数量（GOODS_SCALE 单位，>0）。
- 校验：句柄有效、good 合法、国库该物资 ≥ value（考虑同批次前序命令已扣减量），否则整批拒绝
  `country_treasury_goods_insufficient`。
- 效果：国库物资减少；每国 transient 计数 `treasury_goods_consumed_total += value`
  （不进 PKCN/hash/CPD2；读档归零）。
- 同步批次路径（`country_runtime.cpp` staged batch）与 POD 路径（`country_core_apply.cpp`）都要实现。
- 经济货物审计：`sample_economy_goods_audit` / 研究消耗同口径，把 `treasury_goods_consumed_total`
  的周期增量作为 goods sink 扣除（与 `_country_research_goods_consumed` 并列），保证 goods_err = 0。
- GDScript：`CountryFacade.Opcode.CONSUME_TREASURY_GOODS = 21`，以及
  `CountryFacade.advance_era(handle, milestone_technology_id: StringName, good_indices: PackedInt32Array,
  quantities: PackedInt64Array, effective_day, sequence) -> Dictionary`：一次 `submit` 提交
  n 条 CONSUME + 1 条 GRANT_TECHNOLOGY。

### 2.2 经济命令：国家购买政策

`EconomyFacade.set_country_procurement_policy(country_handle, enabled: bool,
treasury_share_bp: int /*每日国库现金份额，0..10000*/, research_share_bp: int /*0..10000*/,
effective_day, sequence) -> Dictionary`

- 设置了政策（enabled）的国家：
  - `national_daily = country_cash × treasury_share_bp / 10000`（周期开始冻结；周期预算 = 日额 × epoch_days）。
  - `research_daily = national_daily × research_share_bp / 10000`；研究采购使用它代替 Country 的
    `research_daily_budgets`（Country 的 auto_purchase 开关仍是总开关）。
  - `other_daily = national_daily - research_daily`；若该国本周期无研究需求，研究份额并入 other。
  - other 由「时代收购」与「派遣储备」共享：两者都有需求时各 50%，只有一方时全给该方。
  - 派遣储备（`refresh_epoch_colonization_demand` 预算与筹备期实际国库采购）受派遣份额上限约束
    （按日补充的额度，未用完不累积超过 1 个周期）。
- 未设置政策的国家（外国 AI）保持旧行为。

### 2.3 经济命令：时代收购目标

`EconomyFacade.set_era_procurement_target(country_handle, active: bool,
good_indices: PackedInt32Array, required_quantities: PackedInt64Array, effective_day, sequence)`

- `active=false` 清空该国目标（暂停）。已买入国库的物资不退回。
- 每个周期：`remaining[g] = max(0, required[g] - 国库现有[g])`；按 `(country, good 顺序, price, cell)`
  稳定顺序扫描本国属地市场剩余库存（在私人购买之后、研究采购之后），只向有活商人的市场付款，
  走 `GOOD_FROM_MARKET`（现金付当地商人，市场库存 → 国库物资），受时代收购份额与国库现金约束。
- 计入需求 EMA/价格形成（与研究采购相同口径），以及非税支出新槽 `era_procurement`
  （`NON_TAX_ERA_PROCUREMENT`）。现金/货物守恒必须保持。
- 目标表为 transient（不进 PKEC）；读档后由玩家会话重推。

### 2.4 查询

`EconomyFacade.country_procurement_snapshot(country_handle) -> Dictionary`：

```
{ ok, policy_enabled, treasury_share_bp, research_share_bp,
  national_daily_budget, research_daily_budget, other_daily_budget,   # MONEY_SCALE 现金
  era_active, era_daily_budget, colonization_daily_budget,
  era_goods: [ {good_index, required, treasury_stock, remaining, purchased_total} ],
  era_cash_spent_total, era_last_epoch_cash, research_cash_spent_last_epoch,
  colonization_cash_spent_last_epoch,
  trade_orders_total }   # 本会话累计、该国作为来源或目的地的贸易订单数（国内+跨国）
```

`trade_orders_total` 是 transient 单调计数；玩家会话按日差分累加「本时代贸易次数」，读档后以新值为基线。

## 3. GDScript 玩家会话（B1）

- `scripts/era/era_advancement_catalog.gd`（静态）：每个目标时代（1..10）的
  `population / buildings / trade_orders` 阈值、收购物资清单 `[{good_id, per_cell, floor}]`、
  buff 文案（与里程碑 `modifier_terms` 一致）。
- `scripts/era/era_advancement_service.gd`：状态机
  `LOCKED → READY → PURCHASING ⇄ PAUSED → COMPLETING → (era+1) LOCKED/READY`；
  开始时冻结地块数与物资需求；每日刷新条件与进度；国库达标即提交 `CountryFacade.advance_era`；
  Country ACK（时代 index 变化）后清空经济目标、重置本时代贸易基线。
  `to_save()/restore()` 进入 `player_view`。
- `PlayerController`：
  - 新命令 `era.advance.start / era.advance.pause / era.advance.resume`，`procurement.set_policy
    {treasury_share_bp, research_share_bp}`。
  - `get_era_advancement_snapshot()` 返回 UI 模型（见 §5）。
  - `research.enqueue/move` 拒绝里程碑科技：`technology_milestone_retired`。
  - 会话开始/读档时推送政策与时代收购目标（默认国库 2%/日，科技 50%）。

### 3.1 B1 实现备注（2026-11-01）

- 授予规则：当前时代 c = `CountryFacade.current_era_index`（无里程碑也为 0 = 石器）；
  晋升目标 c+1，`advance_era` 授予 `eras[c+1].milestone_id`。石器里程碑
  `tech.settled_knowledge` 作为**首次晋升的前奏**：开始收购时单独
  `grant_technology` 授予（其 buff 与石器时代奖励在收购期间生效），只有它
  state 5 后才提交 `advance_era(tech.agrarian_society)`。
- 时代奖励三选一仍由里程碑激活原生触发。若上一份奖励仍为 OPEN/SELECTED_PENDING/ERROR，
  原生 planner 会拒绝新的里程碑通知，所以物资备齐后也要等奖励领取完再提交
  （`PlayerController.get_era_advancement_blocked_reason()` 给出提示）。
- 条件口径：tech = `era_id == 当前时代` 的非里程碑科技 state 5 比例 ≥ 50%；人口
  `country_economy_overview(summary).population`；建筑 `building_units`；贸易 =
  `country_procurement_snapshot.trade_orders_total` 的会话内日差分（缺接口时为 0）。
- 提交后进入 COMPLETING 并推送 active=false；5 日内里程碑未进入 pending/完成则回到
  PURCHASING 重推目标；`advance_era` 被拒则停在 PURCHASING 次日重试。
- `player_view.era_advancement`（version 1）：`phase, target_era, frozen_territory,
  required_good_ids, required_quantities, known_era, trade_era, trade_accumulated,
  completion_day, prelude_granted, treasury_share_bp, research_share_bp`。
- 信号：`PlayerController.era_advancement_changed(snapshot)`、
  `era_advanced(old_index, new_index, buffs: PackedStringArray)`。
- 校验器：`TechnologyNetworkValidator.effect_summary` 对里程碑输出
  「时代晋升效果：…」，权威作者门禁会保持该前缀。

## 4. 科技数据与科技 UI（B1 数据，B3 UI）

- `technology_network.json`：11 个里程碑节点保留 id/era/成本，但：`effect_summary` 改为
  「时代晋升效果：…」，新增显式 `modifier_terms`（运行时已消费的 stat），文案对玩家显示在时代面板。
- 科技 UI 全面隐藏里程碑：可研究清单、聚焦树（含底部「时代里程碑关隘」）、总览计数、搜索、
  详情前后置、KPI「当前时代」仍按已生效里程碑显示。
- 国库面板（`EconomyWorkspace` 国库区）新增「国家购买预算」滑条：0–10%/日（最左关闭），
  显示每日预算、科技/派遣/时代三项分配与上一周期实际支出。
- 科技面板 `ProcurementBudgetSlider` 改为「国家购买中科技占比」0–100%，显示折算后的每日科技预算。

## 5. 时代面板与演出（B2）

`PlayerController.get_era_advancement_snapshot()` 模型：

```
{ ok, current_era_index, current_era_name, next_era_index (-1 = 已到最高), next_era_name,
  status: "locked"|"ready"|"purchasing"|"paused"|"completing"|"max",
  conditions: [ {key: "tech"|"population"|"buildings"|"trade", label, current, target, met, text} ],
  conditions_met, conditions_required (=2), can_start,
  territory_count, frozen_territory_count,
  costs: [ {good_id, name, required, in_treasury, ratio} ],   # GOODS_SCALE
  progress (0..1),
  buffs_preview: PackedStringArray,
  budget: {national_daily, era_daily, treasury_share_bp, research_share_bp} }
```

- 时代 icon 点击 → 打开时代晋升面板（替代原「国家概况」直接展开；概况保留为面板中的页签或下方区块）。
- 面板按钮：开始晋升 / 暂停 / 继续，调用 `PlayerController.request_command`。
- 晋升完成演出（重点）：全屏压暗 → 旧徽记碎裂/燃尽 → 新时代徽记从光柱中升起（放射光芒、
  粒子、镜头轻震）→ 书法大字「进入××时代」与副标题 → 逐条展开获得的 buff → 徽记飞回顶栏，
  日历时代名换字；音频沿用 `GameAudioService.set_era` 的时代礼乐。可跳过（点击/Esc），
  暂停时钟期间播放，读档/新世界不重播。

### 5.1 UI 实现（B2）

- 层级：纸徽 `EraIndicator` 与日期栏同级，挂在 `UIRoot/HUDLayer` 末位——画在顶栏之上、所有面板之下。
  国家卷宗的压暗遮罩、右侧检视面板、暂停菜单与奖励弹窗都能盖住它；它不是一个常驻最高层。
  纸笺与晋升光带留在 `EraOverlayLayer`（`PanelLayer` 之上、`ModalLayer` 之下），
  卷宗开着时的晋升反馈另由高 z 的 `ResearchToast` 纸贴保证可见。
- 纸徽速览（国家概况 + 时代晋升合并）：`scenes/ui/era_advancement_panel.tscn` +
  `scripts/ui/components/era_advancement_panel.gd`（`EraAdvancementPanel`），由 `GameUIManager` 挂到
  `UIRoot/EraOverlayLayer`（`PanelLayer` 之上、`ModalLayer` 之下；打开国家卷宗会先收起纸笺）。
  点击纸徽只打开这一张纸笺：**无页签、无 ScrollContainer**。
  - 版式：宽 760–920、高恒为 600 的两栏纸笺，内边距 30px，全部按固定行高自绘（`region_tooltip_canvas.gd`
    登记分区提示）；字号只用 22/14/13，语义色只用墨、铜绿、朱砂；文字单行截断加「…」，全文进提示。
    纵向放不下时纸徽保持半露、纸笺上移，再整体等比缩小，从不滚动。纸笺下的柔光由 Sheet 自绘
    （9 层同形圆角矩形，无填充底板），不使用纸张贴图做影子。
  - 左栏「国家概况」：国名；七格指标（年度 GDP、人均 GDP 带金币，CPI、PPI、地块、满意度、生活水平）；
    问题纸贴最多 2 条 +「+N」（全文在提示）；待领奖励时显示一个「领取时代奖励」按钮（三张奖励纸片仍走
    `EraRewardDialog` 原流程）。数据来自 `EraIndicatorViewModel.build_overview()`。
  - 右栏「时代晋升」，每项只出现一次：kicker「时代晋升」；时代行「A → B」+ 右侧状态签（收购中 n% /
    条件未满足 / 可开始 / 已暂停 / 已完成 / 已达最高时代）；徽记带（当前 64px、2px 进度轨 + 箭头、
    下一时代 80px + 同进度金环，徽记下无文字）；「前提条件 · 任选其二」+ 同行「已满足 n/2」；条件 2×2
    （勾选、图标、标签、右对齐「n / m 单位」，无迷你进度条）；「晋升物资」小签最多 4 个（中文名 +
    「n / m」+ 细条，第 5 种起收成「+N 种」，地块计价进小节头提示）；预算一行「时代收购 · 每日 金币 X」，
    预算为 0 时改为可点的「尚未分配预算 · 前往国库设置」；「晋升后获得」逐条全列（>4 条两列）；
    笺线下操作行：左侧只写增量（如「差 22 座建筑」「还差 2 项条件」），右侧自动宽度朱砂蜡印按钮。
    `max` 状态右栏为当前徽记 +「已获得的时代加成」全列。
  - 物资名：服务未取到经济门面时快照里是内部 id，VM 回落到 `data/goods/<id>.tres` 的 `display_name`。
  - 读数经 `EraIndicatorViewModel.present_advancement(snapshot)` 格式化（GOODS_SCALE/MONEY_SCALE、
    `IconCatalog.good_semantic`、按钮决策）；只在 `era_advancement_changed` 与既有 100ms 合并刷新
    定时器上刷新。旧的「纸徽 → EraRewardDialog 概况页」入口已移除（概况页只在三选一流程中出现）。
- 纸徽 `EraIndicator.set_advancement(status, progress)`：收购中金色自上而下漫溢（progress = 快照
  progress），暂停时淡金静止，READY 时外缘呼吸；里程碑研究进度与 `researching/research_name` 已移除。
- 大典 `scenes/ui/era_ascension_ceremony.tscn` + `era_ascension_ceremony.gd`（`EraAscensionCeremony`），
  挂 `UIRoot/ModalLayer`，排在 `PauseMenu` 之前。着色器：`shaders/ui/era_ceremony_backdrop.gdshader`
  （压暗/去色/暗角/光柱/放射/冲击波/爆闪）、`era_emblem_dissolve.gdshader`（燃尽与凝形）、
  `era_brush_reveal.gdshader`（书法运笔）；粒子一律用 `CPUParticles2D`（Mobile/Web 兼容）。
  触发源有两个：`PlayerController.era_advanced`，以及纸徽检测到会话内时代上升；二者按
  `_era_celebrated_index` 去重，读档/新世界的第一份模型只建立基线。纸徽 `defer_celebration=true`：
  保留旧图标，新徽记飞回后才换图、放金环，并把光点送到日历换字。演出开始时若时钟在跑则暂停，
  结束后只在没有其他流程（奖励/家族/意识形态/暂停菜单）接管时恢复。
- 回归：`tests/ui/era_advancement_panel_test.gd`（全部 6 种状态 × 长文本 × 1280×720/1920×1080/
  125% 缩放：无滚动、纸笺高度一致、落在视口与纸徽之下）、`tests/ui/era_indicator_ui_test.gd`；
  可视化探针 `tests/probes/_probe_era_ceremony.gd`（截图输出到 `tmp/era_advancement_qa/`）。

## 6. 存档

- PKCN：不新增持久字段（transient 计数不入档）。catalog identity 因科技数据变化而改变，旧存档
  按既有策略返回 `catalog_hash_mismatch`。
- PKEC：不新增字段（政策与目标 transient）。
- `player_view`：新增 `era_advancement` 字典（状态、冻结需求、贸易基线、政策）。

### 2.5 时代收购不再声明 self-settled（2026-11-02 修复）

现象：时代收购一旦真正开始买货，经济阶段停在 `stage=government_research_procurement / substage=era_asset_peer_pending`，
5 秒后 `[day-stall-fault] code=economy_fiscal_peer_stall_timeout` → worker FAULTED、时钟暂停。

根因：`run_government_era_procurement` 在 Country worker 路由下把 GOOD_FROM_MARKET 请求
`defer_country_economy_asset_settlement`（self-settled）。该标记使
`country_authority_drain_idle_locked()` 持续为假、通用 flush 也不扫这笔请求，于是 Country worker
永远跑不到能提交它的那一天，Economy 阶段就一直 park 在同一笔在途请求上。
同一阶段的科研采购走的是另一种写法：只置 `host_peer` 并轮询 terminal，不声明 self-settled。

修复：删除时代收购 enqueue 分支里的 defer 调用（`gdext/src/economy_runtime_procurement.cpp`）。
self-settled 只保留给「在本轮经济周期之外结算」的续接（家族开拓筹备，在 idle 边界结算）。

验证：`_probe_era_norsrch`（把科技预算份额设为 0，全部给时代收购）从 day 5 跑到 day 584+，
`economy-fiscal-stall` 出现 0 次；国库实际入账 `era_spent=653660`、原木 40000/40000、
采集植物 60000/60000。回归：`era_procurement_runtime_test`、`country_runtime_test`（58/0）、
`technology_procurement_runtime_test`、`era_advancement_service_test` 全部通过。
### 2.6 首次晋升的收购物资必须在开局市场可买（2026-11-02 修复）

真机验证发现：石器→农耕原本要求 `flint`，但开局经济里没有任何人生产燧石，本地市场始终 0 库存，
时代收购进度停在 66.7% 且永不完成——玩家会永久卡在第一次晋升。

实测开局市场只有四类可交易物资：`clothing` / `game_meat` / `gathered_plants` / `logs`。
因此首晋升改为 `logs / gathered_plants / game_meat`（`scripts/era/era_advancement_catalog.gd`），
并在 `era_advancement_service_test.gd` 增加硬断言：首晋升的每项物资必须属于开局市场可售集合，
防止后续内容调整再次引入「买不到」的物资。

真机端到端（`_probe_era_e2e_d5`）：强制开始晋升 → 经济持续收购 → 国库 logs 40000/40000、
gathered_plants 60000/60000、game_meat 30000/30000 → 自动消耗并晋升，`era 0 → 1`，
`era_advanced` 携带两代 buff（农业产出 +4%/+8%、人口死亡率 −4%/−5%、社会研究 +5%、国内贸易容量 +5%），
**PASS**。