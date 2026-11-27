# 阶层组织度与叛乱事件链：评估与设计提案

- 日期：2026-11-13
- 状态：**已实现**（评估稿保留为设计依据；代码契约见 [stratum-mobilization.md](../cpp-dots-runtime/stratum-mobilization.md)）
- 范围：玩家国家地块上「职业 × 组织度」的累积/衰减、四阶叛乱事件链、让步/镇压的成功率、成功叛乱后的独立与战争
- 关联文档：[综合满意度运行时](../cpp-dots-runtime/satisfaction-runtime.md)、[显赫家族运行时](../cpp-dots-runtime/notable-family-runtime.md)、[军事运行时](../cpp-dots-runtime/military-runtime.md)、[叙事事件写作](../design/narrative-event-authoring.md)、[架构目标](../architecture/design.md)、[当前状态](../architecture/current-state.md)
- 证据口径：本文的 `file:line` 均来自本次实际读到的代码/文档；标 **UNVERIFIED** 的条目表示只读代码、未跑测试或未实机验证。

> **实施进展（2026-11-13，已收口）**：四项决策已定稿——独立必须新建国家；**所有国家都有首都**（= 世界生成起始格，PKCN v16 `capital_cell`），首都不可独立；AI 照常计算但不给玩家弹窗；独立后由原主权国"朝廷讨伐"宣战。Phase 0、M1 原生核心、M2 成功率/结算/四阶事件链、M3 建国/强制宣战/驻军转移、AI 原生自动决议、地块「民情」页签、地图告警与顶栏离心纸签均已落地；黄金 v4/v2/v3 与外部位移 v5 已按 5 次捕获重录并通过。验证：`country_capital_test` 16/0、`satisfaction_runtime_test` 58/0、军事自测 PASS、叙事 79/0、`stratum_unrest_service_test` 7/0、`golden_day_hash_test` 176/0、`golden_external_advancers_test` 338/0。实现细节见 [stratum-mobilization.md](../cpp-dots-runtime/stratum-mobilization.md)。
>
> **节奏修订（2026-11-27）**：§3.3/§3.4 的「升级判定 0.35」改为**阈值驱动**（对齐 Victoria 3 式机制）：行动失败不再直接升阶，只增加组织度/后遗症并把下一次检查推后；链只在 `next_check_day` 到达且组织度（及 power）越过下一阶门槛时升阶。成功则降阶并把下一次检查推到冷却结束。第 4 阶镇压失败才直接独立，第 3 阶镇压失败不再跳过「举旗」事件。代码契约见 [stratum-mobilization.md](../cpp-dots-runtime/stratum-mobilization.md) §4。
>
> **最后一城（2026-11-27，方案 D）**：只剩一座城时保留「不能独立」的保护；取消建国请求，给玩家一条「最后一城不能独立」提示，并在次日清掉该格的独立位。玩家保留城市，不进入零领土状态；链条停在当前阶。

---

## 0. 结论摘要

六条需求在当前引擎里**都有落点**，但难度不在事件文案，而在三处工程决策：

1. **状态归属**：组织度是 per-(地块 × 职业) 的持续状态，必须持久化、可确定性重放。建议归 **Economy**（满意度、职业份额、家族影响力都在那里），**不新建日域**——新增 `RuntimeDomainId` 会改 ABI（[development-guide.md:152](../architecture/development-guide.md)）。
2. **权威掷骰位置**：成功率若在 GDScript 里算、在 native 里改状态，会出现"显示 62%、实际另一套"的双公式。建议 **native 拥有组织度与成功率查询**，叙事层用同一函数返回的概率掷骰，再把结果作为命令交回 native 执行。
3. **独立的跨域簿记**：`create_country` / `transfer_territory` / `war.declare` 都已存在且可从 GDScript 调用（§1.5），但"新国家"要在 Economy 国家表、Ideology 快照、Military 战区、UI 配色/名字上同时成立；且**玩家身份是从起始格反推的**，起始格一旦独立，玩家身份会静默改绑。这是全案**最高风险项**。

其余结论：

- 满意度是**每 1–5 天结算一次的离散值**（`MARKET_CYCLE_MIN_DAYS=1`、`MAX=5`），且发布存在 `wait_commit` 滞后。组织度必须用**对满意度的 EMA** 做输入，否则会随结算抖动。
- 现有"社会压力"事件（5 档、仅跨越时发布）已经占了"民生不满"的叙事位；组织度不能做成第二套平行的不满系统，必须明确分工：**社会压力=温度计，组织度=气压计，叛乱链=风暴**。
- 四阶事件链用现有叙事运行时**可以搭**，但现有系统**没有一等公民的 chain**：`chain_id` 只是元数据，链靠 `SCHEDULE_FOLLOWUP_EVENT` 逐幕排程；排程事件会**绕过 60 天弹窗间隔与每格每年 2 次额度，且不复核条件**。组织度阶段必须由 native 在链结束时主动取消后续排程。
- "成功率随局势浮动"是叙事运行时目前**明确没有**的能力（`NarrativeOutcome.probability_q16` 是静态权重），需要一处小扩展：在 `choose_option` 里按 ctx 调整权重，或给 Outcome 加 `weight_rules`。
- 玩家可见性比数值更重要：组织度到 25–30% 就必须在地图上被看见（告警图标 + 档案页），否则叛乱是"凭空掉下来的惩罚"。

**推荐路线**：先修 5 个前置项（§0.1）→ M0 只读查询 → M1 组织度状态 + UI 预警 → M2 事件链 + 成功率 → M3 独立与战争。每个阶段都能独立验收、独立回滚。

### 0.1 必须先修/先验证的 5 件事

| # | 问题 | 证据 | 不修的后果 |
| --- | --- | --- | --- |
| 1 | 叙事采样的 `satisfaction` **确实**长期是默认 0.65 | 初始化 `ctx["satisfaction"]=0.65`（`narrative_context_sampler.gd:154-156`）；只有 `population_cell_summary` 返回 `composite_satisfaction_q16` 才覆盖（`:304-312`），而 native 从不产出该键（全仓仅测试 fake 提供） | 所有 `SATISFACTION_GTE/LTE` 条件恒按 0.65 判定；可用 `COHORT_SATISFACTION_LTE`（读 `neediest_cohort_satisfaction`，来自真实 cohort 明细）临时绕过；根本修法是让采样器改读 `economy_facade.cell_satisfaction_attractiveness(cell).composite_q16`（该查询已存在，返回 `composite_q16 / social_pressure_level / dim_values_q16`） |
| 2 | 割地时的驻军转移是 no-op | `on_cells_ceded_or_annexed` 调 `transfer_garrison_owner(cell, -1, new_owner)`（[military_core_war.cpp:1376](../../gdext/src/military_core_war.cpp)），而该函数只在 `country_slot == from` 时改（[:1128-1133](../../gdext/src/military_core_war.cpp)）→ `from=-1` 永远不匹配 | 独立后旧驻军仍留在"叛军格"，归属与地图不一致 |
| 3 | 最后一格不能独立 | `country_last_territory_protected`：任何使仍活跃国家 `territory_count == 0` 的批次被整批拒绝（[country_runtime.cpp:4240-4245](../../gdext/src/country_runtime.cpp)） | 玩家丢最后一格时 `create_country` 会被静默拒绝，事件"成功了却没独立" |
| 4 | 玩家身份**每次命令**都从起始格重解析 | `_resolve_player_country()` 取 `gameplay_start_report().cell` → `cell_summary(start_cell).country_handle`（[player_controller.gd:1647-1662](../../Project/project-keynes/scripts/game/player_controller.gd)），并在 `request_command` 等多处调用（`:617,808,819,832,898,908,936`）；视野侧同样反推（[world_runtime_visual_adapter.gd:444-460](../../Project/project-keynes/scripts/game/world_runtime_visual_adapter.gd)） | 起始格一旦独立，玩家下一条命令就会操作**叛军国**；无 `is_player` 标记、无 game over |
| 5 | PKEC 版本漂移 | writer `SCHEMA_VERSION=61`（`economy_runtime.h:216`），reader 接受 61/59/58/57/56（`persistence_read.cpp:42-46`），文档与契约仍写 60 | 新增存档段时基线不清，验收无法对齐 |

第 1 项已确认，是**现网 bug**，应优先修；第 2、3、4 项是叛乱独立的前置条件；第 5 项在动存档前必须对齐。

---

## 1. 现有基础核对

### 1.1 满意度：per-cohort、八维、逐 epoch 结算

| 事实 | 证据 |
| --- | --- |
| 满意度是 cohort 级列，不是地块级标量 | `PopulationStore.composite_satisfaction`(u16)、`satisfaction_dims`(u16×8)、`worst_dimension_id`(u8)（[runtime_economy_population_store.h:44-50](../../gdext/src/runtime_economy_population_store.h)） |
| cohort 身份 = `(cell, signature)`；signature = 职业 × 族群 × 消费计划 | [economy_runtime_internal_planning_types.h:466-475](../../gdext/src/economy_runtime_internal_planning_types.h)；文档称同一 `(cell, profession, ethnicity)` 只保留一个聚合 cohort（[native-economy-runtime.md:781](../cpp-dots-runtime/native-economy-runtime.md)） |
| 当前只有 1 个族群，实际等价「每格每职业一个 cohort」 | `data/economy/ethnicities/default.tres`；INIT 时 signature 为职业×族群笛卡尔积（`economy_runtime_catalog.cpp:1434-1451`） |
| 八维：生存/基本/舒适/奢侈/收入/储蓄/税负/社会发展，合成有生存与基本闸门 | [satisfaction-runtime.md:7-95](../cpp-dots-runtime/satisfaction-runtime.md) |
| 结算节拍是市场 epoch，**1–5 天** | `MARKET_CYCLE_MIN_DAYS=1`、`MARKET_CYCLE_MAX_DAYS=5`（[economy_runtime.h:245-246](../../gdext/src/economy_runtime.h)） |
| 发布有 `wait_commit`，读到的是 sample_day+N-1 之前的已提交值 | skill `scheduling-performance.md` §1/§3；[current-state.md:202](../architecture/current-state.md) |
| 已有「地块 × 政治阶层」即时聚合（冷路径，单批 ≤128 格） | `cell_situation_snapshot`（[economy_runtime_queries_situation.cpp:60-118](../../gdext/src/economy_runtime_queries_situation.cpp)） |
| 已有地块级满意度聚合查询 | `cell_satisfaction_attractiveness` → `composite_q16`、`social_pressure_level`（[economy_runtime_queries_market_building.cpp:406-467](../../gdext/src/economy_runtime_queries_market_building.cpp)） |
| 社会压力 5 档，只在等级跨越时发事实 | `publish_social_pressure_facts`（[economy_runtime_events.cpp:168-227](../../gdext/src/economy_runtime_events.cpp)）；阈值 `[0.2,0.4,0.6,0.8]`（[satisfaction-runtime.md:118](../cpp-dots-runtime/satisfaction-runtime.md)） |
| 压力等级逐格持久化 | `_cell_social_pressure_level`（[satisfaction-runtime.md:159-160,234](../cpp-dots-runtime/satisfaction-runtime.md)） |
| 长跑 730 日全局满意度 71–85%，玩家国 81–91% | [economy-balance-2026-11-08.md:91-97](../cpp-dots-runtime/economy-balance-2026-11-08.md) |

**对设计的直接约束**：

- 组织度输入必须用 `s_ema`（对 composite 做时间常数约 10–15 天的 EMA），不能用单次结算值。
- 组织度可以每日推进，但**输入只能读上一 epoch 已发布值**（就业排序读上期 composite 已是先例，[satisfaction-runtime.md:174-176](../cpp-dots-runtime/satisfaction-runtime.md)），不能读当期未提交值。
- 长跑均值 70–85% 意味着：阈值若设在 0.6，正常国家会常年叛乱。**组织度门槛必须落在真正危机区间（0.45–0.5 以下）**，并与"生存维度塌陷"高度相关。

### 1.2 职业与影响力：有就业份额，没有"职业人口份额"

| 事实 | 证据 |
| --- | --- |
| 50 个职业资源，`profession_class_id` 归入政治阶层 | `data/economy/professions/*.tres`（50 个）；[economy_runtime_carrying.cpp:384-401](../../gdext/src/economy_runtime_carrying.cpp) |
| `cell_profession_share_q16` 的语义是**就业人口 / 本地总人口**，失业不计入分子 | [economy_runtime_lineage_metrics.cpp:126-144](../../gdext/src/economy_runtime_lineage_metrics.cpp) |
| 国家级"阶层影响力" = 人口 + 2×业主就业 + 资金/1e6 | [ideology_runtime.cpp:1357-1366](../../gdext/src/ideology_runtime.cpp) |
| 家族有 per-(家族, 地块) 影响力分与威望 I–V | `FamilyCellInfluenceStore`（[runtime_economy_family_store.h:85-103](../../gdext/src/runtime_economy_family_store.h)） |
| 没有 per-(cell, profession) 的人口/现金/资产聚合表或索引 | 只有 cell→page 链表 + `for_each_in_cell`（[runtime_economy_population_store.h:83-92](../../gdext/src/runtime_economy_population_store.h)） |

**结论**：`cell_profession_share_q16` **不能**直接当"该职业在本格的人口占比"用（它是就业份额）。组织度需要自己的 `population_share = Σ cohort.population / cell.population`，按职业分组累加；这个聚合没有现成索引，但可以在结算循环里顺手做。

建议 v1 定义：

```text
share(c,p)     = pop(c,p) / pop(c)                       # 新聚合，人口口径
influence(c,p) = share(c,p) × political_weight(p)        # political_weight 为职业静态系数（0.6–1.4）
```

`political_weight` 放进职业 profile（soldier 1.3、merchant 1.2、serf 0.7 之类），表达"军人/商人更有组织能量"，不需要新模拟。国家级 `class_influence` 只作为**事件档位**的加成，不进触发概率主公式，避免跨尺度耦合。

### 1.3 家族：有威望与满意度，**没有"效忠/支持"**

| 事实 | 证据 |
| --- | --- |
| 威望分 = 25% 人口份额 + 35% 现金份额 + 40% 建筑资产份额 | [notable-family-runtime.md:87-94](../cpp-dots-runtime/notable-family-runtime.md) |
| 威望档阈值 `{0, 2%, 5%, 10%, 20%, 40%}` → 0–5 档；每 30 日错峰评审，连续 2 次同向才升降 | [economy_runtime_lineage_lifecycle.cpp:614-616,668-707](../../gdext/src/economy_runtime_lineage_lifecycle.cpp) |
| 每分支保存成员 cohort 的人口加权满意度 `satisfaction_q16` | [economy_runtime_lineage_lifecycle.cpp:663-667](../../gdext/src/economy_runtime_lineage_lifecycle.cpp) |
| 满意度 < 0.40 只阻止**晋升**，不阻止降级 | 同上 `:685-690`；压力阈值 `[0.2,0.4,0.6,0.8]`（[economy_runtime_internal_settlement_types.h:812](../../gdext/src/economy_runtime_internal_settlement_types.h)） |
| 刷新是每 **4 个 economy epoch** 或结构变化 | `FAMILY_INFLUENCE_REFRESH_EPOCHS=4`（[economy_runtime_commit_execution.cpp:816-823](../../gdext/src/economy_runtime_commit_execution.cpp)） |
| 无 `loyalty / support / opinion / stance / allegiance` 字段 | 全文检索 `runtime_economy_family_store.h`、`gdext/src` 无匹配 |

**设计选择**：需求 4 说"高威望家族支持玩家"。目前没有"支持"这个状态，只能用**威望 × 影响力 × 满意度**构造代理量：

```text
backing(c) = Σ_f w_f · (2·sat_f − 1) / Σ_f w_f        # w_f = prestige_level(f) × influence_score(f)
             clamp 到 [-1, 1]
```

- 只让 `prestige_level ≥ 4`（≥20%）的分支进入分子，避免小族稀释；**"高威望"= IV 档及以上**。
- 高威望 + 高满意度 → 强正；高威望 + 低满意度 → 强负（家族会带头或至少不阻拦）。
- **必须在文档与 UI 里写清这是"民意代理"，不是真正的效忠**；后续若要真正的家族立场，应单独做 `family_loyalty`，不要偷偷改这条公式。
- 家族影响力每 4 epoch 才刷新，`backing` 因此有 4–20 天滞后；UI 不显示小数，只显示"拥护/观望/离心"三档。

### 1.4 驻军与战争：per-cell 驻军可查，但查询是全表扫描

| 事实 | 证据 |
| --- | --- |
| 每格每国的驻军人数 | `garrison_heads_at(cell, country_slot)`（[military_core.h:1054](../../gdext/src/military_core.h)）；**全表扫描，无索引**（[military_core_war.cpp:1116-1126](../../gdext/src/military_core_war.cpp)） |
| `present_for_cell` = 驻扎部队 + 全部驻军 lot，**不分归属** | [military_core.cpp:1417-1428](../../gdext/src/military_core.cpp) |
| `posts_for_cell(cell, country_slot)` 的 `country_slot` 被忽略（`(void)country_slot`） | [military_core.cpp:1397-1415](../../gdext/src/military_core.cpp) |
| 地块军事快照含 `garrison_lots`（按 `country_slot` 过滤） | `get_military_cell_snapshot(cell, observer)`（[world_ext_military.cpp:2986-3092](../../gdext/src/world_ext_military.cpp)） |
| `cell.garrisoned` 标签只表示"有一支部队站在这里"，不等于有驻军 lot | `military_cell_stats_publisher.gd:126-129`；[world_ext_military_cell_stats.cpp:86-96](../../gdext/src/world_ext_military_cell_stats.cpp) |
| 士兵是 Economy 的普通 cohort，驻扎本格；口粮满足率单独发布 | `runtime_economy_army_personnel.h:6`、`military_ration_satisfaction_q16`（[economy_runtime.h:1381](../../gdext/src/economy_runtime.h)） |
| 宣战是军事命令 `MCMD_WAR_DECLARE=40`，**要求攻方有兵** | [military_core.h:734](../../gdext/src/military_core.h)、[military_core_war.cpp:407-435](../../gdext/src/military_core_war.cpp) |
| 建军 `MCMD_ARMY_CREATE=20` **只能从本地驻军 lot 抽人**，没有驻军会销毁幻影部队 | [military_core.cpp:2650-2689](../../gdext/src/military_core.cpp) |
| 战斗只打部队 vs 部队；`local_defence` 由人口推导，**驻军 lot 不参战** | [military_core_war.cpp:186-199](../../gdext/src/military_core_war.cpp)、`:838-859` |
| 割地时 `transfer_garrison_owner(cell, -1, …)` 是 no-op | [military_core_war.cpp:1372-1381,1128-1133](../../gdext/src/military_core_war.cpp) |
| Military 是主线程推进者，按已提交日期追赶 | [current-state.md:212](../architecture/current-state.md) |

**缺口**：

- 没有"脚本直接把某格驻军转给叛军"的公开命令；`transfer_garrison_owner` 私有且割地路径调用有 bug。
- 没有"不战斗也能让某格进入敌对状态"的原语；`capture_cell` 是唯一写 `_cell_controller` 的地方。
- 驻军强度只能作为**抽象加数**进入镇压成功率；现有战斗系统里驻军不参战，所以"驻军镇压叛乱"不能复用战斗。

### 1.5 建国与领土：命令已存在，`create_country` 是"抢一格"

| 事实 | 证据 |
| --- | --- |
| `COMMAND_CREATE_COUNTRY=1`，带 `stable_id / display_name / cell` | [country_api.h:69-72](../../gdext/src/country_api.h) |
| `create_country` 会**夺取一个已归属的陆地格**，旧主人 `territory_count−1`，新国继承旧主人科技，政体默认 `early_clan`，现金/物资为 0 | [country_core_apply.cpp:366-473](../../gdext/src/country_core_apply.cpp)；同步实现 [country_runtime.cpp:3454-3558](../../gdext/src/country_runtime.cpp) |
| `COMMAND_TRANSFER_TERRITORY=3`、`COMMAND_ANNEX_COUNTRY=27` | [country_api.h:69-118](../../gdext/src/country_api.h) |
| GDScript 门面已暴露 `create_country` / `transfer_territory` / `annex_country` | [country_facade.gd:222-236,350-356](../../Project/project-keynes/scripts/country/country_facade.gd) |
| 批次预检是整批的：任何使仍活跃国家 0 格的批次被整批拒绝 | `country_last_territory_protected`（[country_runtime.cpp:4240-4245](../../gdext/src/country_runtime.cpp)） |
| 国家槽只追加、不复用；`create_country` 需要唯一 stable_id + 非空显示名 | [country_runtime.cpp:3455-3474](../../gdext/src/country_runtime.cpp) |
| 原无首都概念；PKCN v16 新增每国 `capital_cell`（= 起始格）；旧军事 digest 的 -1 只表示未设置 | [country_runtime.h](../../gdext/src/country_runtime.h) |
| 玩家句柄由起始格反推，无 `is_player` 标记 | [world_runtime_visual_adapter.gd:444-460](../../Project/project-keynes/scripts/game/world_runtime_visual_adapter.gd) |
| 无 game over / 亡国判定 | 全仓检索无匹配 |

**结论**：需求 5 的"独立"**不需要新写国家系统**。最省事的路径是**一次 `CREATE_COUNTRY` 批次**（它本身就抢走该格），而不是 `CREATE`+`TRANSFER` 两步。但必须处理"最后一格"和"玩家身份改绑"两件事。

### 1.6 事件链：机制够用，但没有一等公民的 chain

| 能力 | 现状 | 证据 |
| --- | --- | --- |
| 触发通道 | `PULSE_SAMPLED / FACT_DRIVEN / SCHEDULED_ONLY` | [narrative_event_definition.gd:9-13](../../Project/project-keynes/scripts/narrative/narrative_event_definition.gd) |
| 事实驱动 | `fact_event_type` + GameplayEventBus（type 8 = 社会压力） | [narrative_event_service.gd:45-61](../../Project/project-keynes/scripts/narrative/narrative_event_service.gd) |
| 条件 | 48 个算子，含满意度、职业份额、最差 cohort 满意度、家族威望/人口/建筑、战争状态 | [narrative_condition.gd:4-56,117-160](../../Project/project-keynes/scripts/narrative/narrative_condition.gd) |
| 选项 | 现金/货物/科技门槛；多 outcome（内容最多 2 个） | [narrative_option.gd:11-45](../../Project/project-keynes/scripts/narrative/narrative_option.gd) |
| 概率 | 每个 outcome 固定 `probability_q16`，**没有运行时计算入口** | [narrative_outcome.gd:6-9](../../Project/project-keynes/scripts/narrative/narrative_outcome.gd) |
| 效果 | 15 种：地块/国家修正、现金/货物、故事 flag、权重偏置、后续排程、家族特质 | [narrative_effect_spec.gd:7-24](../../Project/project-keynes/scripts/narrative/narrative_effect_spec.gd) |
| 链 | **没有 `chain_id` 字段**；`tag_key` 只作为元数据带进 record，运行时不读它做门/计数/去重 | 报告证据：`narrative_effect_adapter.gd:299-308`、`narrative_event_service.gd:1353` |
| 排程 | `SCHEDULE_FOLLOWUP_EVENT`：`target_key`→event_id、`tag_key`→chain_id、`due_day = effective_day + max(1,duration_days)` | [narrative_effect_adapter.gd:299-308](../../Project/project-keynes/scripts/narrative/narrative_effect_adapter.gd) |
| 排程的副作用 | **绕过 60 天弹窗间隔与每格每年 2 次额度；到期不复查 conditions/flag/one_shot；目标事件不存在则静默丢弃** | `narrative_event_service.gd:399-428`、`:1144-1147`、`:1253-1256` |
| 确定性 | 无状态哈希 RNG（seed/day/country/cell/salt） | [narrative_rng.gd:14-33](../../Project/project-keynes/scripts/narrative/narrative_rng.gd) |
| 结果掷骰 | salt 用 `offer_id`（会话内自增），读档重开同一事件会得到不同结果 | [narrative_event_service.gd:1313-1315](../../Project/project-keynes/scripts/narrative/narrative_event_service.gd) |
| 节奏 | 脉冲 20 天 × 25%，全局弹窗间隔 60 天，单格每年 ≤2 次 | [narrative_event_service.gd:24-35](../../Project/project-keynes/scripts/narrative/narrative_event_service.gd) |
| 存档 | `PKNarrativeRuntime` v1，含 active_offer / ready_queue / flags / cooldowns / scheduled_events / chronicle | `export_state`/`restore_state`（[narrative_event_service.gd:1421-1465](../../Project/project-keynes/scripts/narrative/narrative_event_service.gd)） |
| 交互 | 弹窗**真的暂停时钟**，且锁住其它命令；**没有超时/忽略/关闭**，GM 屏蔽时自动选第 0 项 | [narrative_event_flow.gd:103-130,186-194](../../Project/project-keynes/scripts/narrative/narrative_event_flow.gd) |

**内容规模（实测）**：179 条事件，167 条 3 选项、11 条 2 选项、1 条 1 选项；482/524 个选项是单结果，42 个是双分支；正文平均 150 字；排程链 2–4 幕、总时长 ≤3 游戏年。

**三处必须补的能力**：

1. **动态成功率**：outcome 概率目前是静态的。最小改法是在 `choose_option` 里按 ctx 调整权重（例如给 Outcome 加 `weight_rules`，或加一个 `probability_from_context` 字段），并同步改 `narrative_ai_validator` 的白名单。
2. **稳定 salt**：现有 salt 用 `offer_id`；叛乱链若要求"读档不改变已定结局"，必须改成 `(chain_id, stage, day, cell, option)` 的稳定哈希。
3. **链级状态**：没有 stage / 链级冷却 / 去重 / 已完成 stage 记录。当前只能靠"每个分支排不同的 event_id"硬编码，四阶三选项会变成组合爆炸。建议在 native 侧保存 `stage`，叙事侧只按 stage 选模板；`SCHEDULE_FOLLOWUP_EVENT` 只负责"下一次检查"，到期由 native 决定是否真的弹。

**另有一处已确认的坑**：叙事采样的 `satisfaction` 恒为默认 0.65（§0.1 第 1 项），所有 `SATISFACTION_GTE/LTE` 条件目前等于没生效。M2 前必须修，或在内容里改用 `COHORT_SATISFACTION_LTE`。

---

## 2. 六条需求逐条评估

| # | 需求 | 现有支撑 | 缺口 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | 低满意度 → 组织度缓升；高满意度 → 缓降 | cohort composite、社会压力、逐格持久化、EMA 先例 | per-(地块×职业) 组织度状态、人口份额聚合、存档列 | **可做**，工作量中等 |
| 2 | 高组织度按概率触发叛乱；影响力越大越易 | 职业份额（就业口径需改）、地块满意度查询 | 触发 hazard、影响力定义 | **可做**，公式需校准 |
| 3 | 按影响力/组织度分四档 | 叙事事件、4 档阈值可自由定义 | 档位与事件链的映射 | **可做**，纯内容+规则 |
| 4 | 挫败概率取决于当地总满意度/家族/驻军 | 家族威望+满意度、驻军查询、地块满意度 | 成功率公式、家族"支持"代理、军人例外、驻军查询性能 | **可做**，需明确"代理"口径 |
| 5 | 成功叛乱 → 独立 + 立刻交战 | `CREATE_COUNTRY`（原子抢格）/ `TRANSFER_TERRITORY` / `WAR_DECLARE` | 最后一格、玩家身份改绑、叛军驻军、宣战需兵 | **可做但高风险**，先 spike |
| 6 | 多选项事件链，成本/收益/概率/延链 | 选项/outcome/后续排程/权重偏置/故事 flag | 动态概率、组织度效果、链级 stage | **可做**，扩展一处运行时 |

### 2.1 需求 1：组织度的累积与衰减

关键判断：**不要把组织度做成"低于阈值就线性加、高于阈值就线性减"的双斜率积分器**。那会产生两个问题：

- 满意度在阈值附近抖动时，组织度会来回抽动，玩家看到"忽高忽低"；
- 无上界时，长期低满意度的格会永久满组织度，叛乱变成周期性刷事件。

建议用**向目标值收敛的稳态模型**（一个参数、天然有界）：

```text
grievance = clamp((θ_low − s_ema) / θ_low, 0, 1) ^ γ
capacity  = floor(p) + (1 − floor(p)) · grievance · (0.6 + 0.4 · min(1, share/0.25))
org      += (capacity − org) · dt / τ
```

- `floor(p)`：职业的"和平时期组织底子"（行会/工会/军营/教会），0.02–0.20；随时代与科技抬升。
- `τ`：上浮 60 天、下沉 35 天；"缓慢"体现在这里，而不是每帧常数。
- `γ≈0.8`：让中段不满也能积累，而不是只有赤贫才动。
- 满意度高于 `θ_high` 时 `grievance=0`，目标回落到 `floor`，自然缓降——满足需求 1 的后半句。

### 2.2 需求 2：触发概率与影响力

```text
p_day = p_base · ((org − gate_k)/(1 − gate_k))^β · w_inf · (0.6 + 0.4·(1 − local_sat))
        上限 0.05/日；org < gate_k 时为 0
w_inf  = clamp(share / 0.25, 0.1, 2.0) · political_weight(p)
```

- `gate_k` 是当前链阶段到下一阶段的门槛（见 §3.4），保证"组织度不够就不出事件"。
- 影响力用**本地人口份额**驱动，符合"这个地块上这个职业的影响力"。
- `local_sat` 只作为温和修正，主驱动仍是组织度——否则又变成"满意度直接决定叛乱"。

### 2.3 需求 3：四档划分

用**冲击力**而不是单一看组织度：

```text
power = org · (0.55 + 0.45 · min(1, share/0.25)) + 0.20 · (1 − local_sat)
```

第二项是"全城都在挨饿"的加成：只有组织度、没有普遍苦难，最多走到示威；只有苦难、没有组织，连不满都成不了链。这样"武装叛乱"必须同时满足**有组织**与**当地普遍不满**，而不是某个小职业自己闷头攒满。

| power | 档位 | 语义 | 事件形态 |
| --- | --- | --- | --- |
| < 0.25 | （未成链） | 只有怨言 | 不弹窗，地图告警 |
| 0.25–0.45 | 不满 | 陈情、联名、怠工 | 地方事件，2–3 个选项 |
| 0.45–0.62 | 抗议 | 聚众、罢市、请愿 | 地区事件，影响产出/税收 |
| 0.62–0.80 | 示威 | 游行、封锁、冲击官署 | 全国可见，附带修正 |
| ≥ 0.80 | 叛乱 | 武装起事 | 战争级事件，可独立 |

组织度与影响力各占一半：一个 5% 人口的小职业即使组织度满，也只是"局部骚动"；一个 40% 人口的阶层在中等组织度就能撼动全城。

**升阶双门槛**：链从第 k 阶升到 k+1，必须**同时**满足 `org ≥ gate_k` 与 `power ≥ tier_k`；只满足其一则链**停在当前阶**（可以重复出同阶事件、间隔更长），不会硬推到叛乱。这保证"小职业闹不大、大职业压不住"。

### 2.4 需求 4：挫败概率

这是全案最容易做成"黑箱"的地方。建议把成功率拆成**玩家能读懂的加数**，并在 tooltip 逐项显示：

```text
P_success = clamp(B_action
  + 0.35 · (local_sat_others − 0.5) · 2        # 当地其他职业的满意度（影响力加权）
  + 0.25 · g_strength                          # 驻军强度
  + 0.25 · family_backing                      # 高威望家族的支持代理
  + cost_bonus(action, spend)                  # 花钱买到的确定性
  − 0.35 · org                                 # 对方的组织度
  − 0.15 · min(1, share/0.25)                  # 起事阶层的体量
  , 0.05, 0.95)
```

其中：

```text
local_sat_others = Σ_{p≠rebel} share_p · sat_p / Σ_{p≠rebel} share_p
g_strength       = clamp(garrison / max(1, rebel_pop · 0.05), 0, 1) · (0.5 + 0.5·ration_sat)
rebel_pop        = cell_pop · share
```

- **驻军**：`0.05` 的含义是"每 5% 的起事人口需要 1 名驻军达到满效果"，可按长跑校准。查询用 `garrison_heads_at(cell, player_slot)`；它是全表扫描，**只在有链的格上调用**，不要每格每日扫。
- **军人例外**：`rebel profession == soldier` 时 `g_strength = 0`，且 `+0.25 · defection`（本地驻军部分倒戈）加到对方；这是需求 4 明确要求的例外。
- **家族**：见 §1.3 的 `backing`；高威望家族满意度高 → 正，低 → 负。
- **当地总满意度**：需求原文用"总满意度"，但又说"其他职业（尤其高影响力）满意度较高"——两者不矛盾：**用排除起事阶层的影响力加权满意度**，避免"叛军自己不满意"把成功率压低。
- **驻军口粮**：`ration_sat` 用 `military_ration_satisfaction_q16(cell)`，饿肚子的驻军镇压效率减半，这是一个便宜且好懂的口径。

### 2.5 需求 5：独立与战争

推荐时序（全部走既有命令）：

1. **一次** `country_facade.create_country("rebel_<cell>_<seq>", <生成名>, cell, day, seq)`
   - 该命令本身就会把 `cell` 从玩家名下夺走、给新国，并继承玩家科技；不需要先 `transfer_territory`。
   - 整批预检保证"要么全成、要么全不成"。
2. 可选传染：对相邻、同职业、`org ≥ 0.6` 的 1–2 格调用 `transfer_territory`（同一批或下一批）。
3. 宣战：`military_facade.declare_war(player_handle, rebel_handle)`。
   - 注意：`MCMD_WAR_DECLARE` 要求**攻方有兵**，所以只能由玩家发起（叙事上写成"朝廷讨伐"，不是"叛军宣战"）。
   - 若一定要"叛军宣战"，需要给新国家生成驻军并放宽/绕过 `country_soldiers(attacker)>0`，这是 native 改动。
4. 叛军驻军：
   - 现在没有"按人口生成驻军"的命令；`army.create` 只能从已有驻军抽人。
   - 方案 A（最小改动）：独立时 native 直接为叛军国在该格生成 `rebel_pop × 0.02` 的驻军 lot（新命令或内部钩子）。
   - 方案 B（更省）：不生成驻军，靠 `local_defence`（人口×2%）让玩家不能无伤收复；战争仍然成立，只是叛军没有进攻能力。
   - 无论哪种，都要修 §0.1 第 2 项的驻军转移 bug，否则旧驻军留在叛军格。
5. 组织度记录：把该格该职业的记录转给新国家或清零，链状态清空；相邻格进入 90 天"震慑"冷却。

**必须先验证的三件事**（spike 清单）：

- 新国家出现在 Economy 的国家表、`_epoch_country_count`、Ideology 的 `country_count` 行、Military 的 `country_slot` 后，各域是否会在下一 epoch 自行扩容而不是越界/静默跳过。
- Military 的 `ensure_country_slot` 会跳过 `handle==0` 的行，而 Country 槽不复用——两边索引空间可能漂移（这是既有风险，叛乱会频繁建国/灭国，必然踩到）。**UNVERIFIED，需专项测试**。
- 玩家失去起始格/最后一格时的行为：无 game over、无 `is_player` 标记；必须先定义。

**如果 spike 失败**，降级方案（按优先级）：

1. 独立=无主格（`owner=-1`，`transfer_territory(..., 0)` 可释放），不建国、不宣战；叛军作为敌对武装占据该格，玩家"收复"即可。语义弱一档，但零跨域风险。
2. 独立=割让给一个接壤的敌国，由该国对玩家宣战（复用现有国家槽）。
3. 独立=延迟到战后和约处理（不做即时独立，只累积"离心"修正）。

### 2.6 需求 6：事件链

推荐**双轨**：

- **native 拥有链状态**：`stage(0–4)`、`org`、`next_check_day`、`cooldown`、`repression_trauma`。
- **GDScript 拥有事件呈现**：根据 native 发布的 `(cell, profession, stage)` 事实，选出对应事件；选项只表达"让步/收买/镇压/无视"的**意图与力度**，具体数值由 native 结算。

这样"成功率随局势变化"不需要在叙事层重算，也不会出现两套公式。流程：

```text
native 组织度跨过 gate → 发 fact(stage, cell, profession)
  → NarrativeEventService 生成 offer（options 带 native 查询到的成功率）
  → 玩家选择 → EffectSpec 调 native resolve(cell, prof, action, intensity)
  → native 掷骰、改 org/stage、记账 → 发 result fact
  → 叙事层展示结果文案（同一弹窗内）
```

若不想加"result fact"，也可以让 EffectSpec 同步返回结果码，叙事层按结果码选 outcome 文案；但 D+1 的命令边界更符合现有架构。**建议同日命令 + 结果事实**，避免玩家点了选项要等一天才看到结果。

---

## 3. 设计提案

### 3.1 命名

军事已有 `organization_q16`（部队组织度）和 `country.military.organization_recovery_factor`。社会组织度**不能**复用 `organization`，否则 UI、存档、搜索都会混。建议：

- 代码：`mobilization_q16`（或 `collective_action_q16`），表 `StratumMobilizationStore`
- 中文 UI：**组织度**
- 事件/文档：阶层组织度

### 3.2 数据模型

`StratumMobilizationStore`（归 Economy，稀疏行）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `cell` | i32 | 地块 |
| `profession` | u16 | dense 职业 id |
| `mobilization_q16` | u16 | 0..65535 |
| `satisfaction_ema_q16` | u16 | 输入 EMA，避免结算抖动 |
| `population_share_q16` | u16 | 上次聚合的人口份额 |
| `stage` | u8 | 0 无链 / 1 不满 / 2 抗议 / 3 示威 / 4 叛乱 |
| `next_check_day` | i32 | 下一次升级判定 |
| `cooldown_until_day` | i32 | 链结束后的冷却 |
| `trauma_q16` | u16 | 镇压后遗症，抬高后续 growth |
| `last_event_day` | i32 | 防刷 |
| `flags` | u8 | bit0=已预警，bit1=军人链，bit2=外族/边区 |

- 键：`(cell, profession)`；每格活跃行数通常 2–5，全球 5k–15k 行。
- 生命周期：人口归零或职业消失 → 删行；地块易主 → 保留 org、清链、给 90 天冷却。
- **不新增 DataCore slot**：这是 Economy 内部状态，经查询发布，不经 `component_schema.gd`；经济硬约束明确禁止 cohort/职业状态进 DataCore。
- 新增持久列的全链路参照 `_cell_social_pressure_level`：`internal_state_members.h` → `economy_runtime.h` 注册 switch → `configuration.cpp` sizing → `reset_state` → `state_hash.cpp` → `persistence_write/read` → `SCHEMA_VERSION` → `runtime_economy_ecp2.h` → `tools/ci/cpp_save_section_contracts.json`。

### 3.3 公式与参数

```text
# 输入
s          = composite_satisfaction(cell, profession) 的人口加权值（上一 epoch 已提交）
s_ema     += (s − s_ema) · min(1, dt/τ_s),  τ_s = 12 天
θ_low      = 0.50      # 低于此开始积累
θ_high     = 0.65      # 高于此回落
γ          = 0.8
floor(p)   = 职业基线组织底子（0.02–0.20）
τ           = 60 天上浮 / 35 天下沉

# 目标与更新
grievance  = clamp((θ_low − s_ema)/θ_low, 0, 1)^γ
capacity   = floor + (1−floor) · grievance · (0.6 + 0.4·min(1, share/0.25))
mob       += (capacity − mob) · dt/τ

# 触发
power      = mob · (0.55 + 0.45·min(1, share/0.25)) + 0.20·(1 − local_sat)
gate       = [0, 0.30, 0.45, 0.62, 0.78][stage+1]
tier       = [0, 0.25, 0.45, 0.62, 0.80][stage+1]
升阶条件    = mob ≥ gate 且 power ≥ tier
p_day      = stage == 0 ? 0.03 · ((mob−gate)/(1−gate))^0.6 · w_inf · (0.6+0.4·(1−local_sat))
                        : (到达 next_check_day 时 0.35，若 mob ≥ gate)
```

**算例（起始值，用于校准方向）**：某格人口 1000，起事职业占 30%，职业 `floor=0.05`，长期满意度 0.30，`τ=60`：

```text
grievance = ((0.50−0.30)/0.50)^0.8 = 0.48
capacity  = 0.05 + 0.95 × 0.48 × (0.6+0.4×1) = 0.506
org(60d) ≈ 0.05 + (0.506−0.05)(1−e^−1) = 0.338   → 约 48 天越过第 1 阶门槛 0.30
power     = 0.338 × (0.55+0.45×1) + 0.20×0.7 = 0.478 → 抗议档
```

也就是说：一座长期满意度 0.30、三成人口是同一职业的城，**约两个月**进入第一阶，**约四个月**到抗议；若满意度继续跌到 0.10 且该职业占一半，`capacity≈0.84`、`power≈0.90`，才会走到叛乱。这个量级符合"组织度是慢变量、叛乱是稀有事"的目标，但必须用长跑校准 `θ_low/γ/τ` 三个参数。

**默认参数表**（起始值，必须用 `tests/economy/economy_balance_soak.gd` 长跑校准）：

| 参数 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `θ_low` | 0.50 | 0.40–0.55 | 开始积累的满意度 |
| `θ_high` | 0.65 | 0.60–0.75 | 开始回落的满意度 |
| `τ_up` | 60 天 | 30–120 | 积累速度 |
| `τ_down` | 35 天 | 20–90 | 回落速度 |
| `γ` | 0.8 | 0.6–1.2 | 中段不满的权重 |
| `p_base` | 0.03/日 | 0.01–0.06 | 首链触发 |
| 升级判定 | 7 天一次，0.35 | 0.2–0.5 | 链推进节奏 |
| 链冷却 | 240 天 | 120–365 | 防刷 |
| 全国同时链 | `1 + era/3`（≤3） | 1–4 | 防事件洪水 |

**校准目标**（可验收）：

- 正常和平年代（全局满意度 70%+）：**每 10 年玩家国 ≤1 次**不满链，0 次叛乱。
- 饥荒/重税/战败年份：**3–12 个月**内出现一条完整链，玩家有 2–4 次干预机会。
- 单次链的弹窗数 ≤4；玩家全部选择让步时，国库成本不超过该地块年税收的 1–2 倍。

### 3.4 状态机

```text
        ┌────────────── 冷却 240 天 ──────────────┐
        v                                          │
  [0 无链] --p_day--> [1 不满] --升级*--> [2 抗议] --升级*--> [3 示威] --升级*--> [4 叛乱]
     ^                   │                  │                  │                  │
     │                   └── 让步成功 ──────┴── 让步成功 ──────┴── 让步成功 ──────┤
     │                          (stage−1, mob−Δ, 冷却 180 天)                     │
     └──────────────────────────── 招安/镇压成功 ──────────────────────────────────┘
                                                                                   │
                                                        镇压失败/弃城 ─────────────┴--> 独立 + 战争
```

规则：

- `升级*` = 同时满足 `mob ≥ gate_k` 与 `power ≥ tier_k`；只满足其一则链停在当前阶，可重复出同阶事件（间隔更长），不会硬推到叛乱。
- 每格同时只有一条链；同日多职业过门槛时，取 `power` 最大者，其余只涨 org 不出事件。
- 链进行中，其它职业的 org 继续累积（可作为"二次叛乱"的种子），但不新开链。
- 链结束（任何方式）都给该格 180–240 天冷却；冷却期内 org 可涨，不出事件。
- 全国链条数上限见参数表；达到上限时只做 org 累积，事件排队。
- **链结束必须显式取消已排程的 follow-up**：叙事排程到点不复查条件（§1.6），否则"链已结束，三天后又弹下一幕"。

### 3.5 事件链内容

四阶 × 3–4 选项（第 1 阶多一个"无视"），共 13 个决策点；另加"军人叛乱"与"商人抗税"两个变体包。每一阶的选项都覆盖「让步 / 收买 / 镇压 / 无视」四种力度，成本和成功率递增/递减。

| 阶 | 事件 | 选项 A（让步） | 选项 B（收买/分化） | 选项 C（镇压） | 选项 D（无视） |
| --- | --- | --- | --- | --- | --- |
| 1 不满 | 陈情与联名 | 减免赋役（中成本，成功 org−0.25） | 召见头面人物（小成本，org−0.15） | 斥责/拘押首倡（免费，低成功，trauma+） | 置之不理（org+0.08，提前升级） |
| 2 抗议 | 罢市与请愿 | 公开谈判（中高成本，org−0.35，stage−1） | 分化收买（中成本，org−0.30，影响力−） | 派兵驱散（需驻军，org−0.20，trauma++） | —（不提供，必须选一个） |
| 3 示威 | 围署与游行 | 承诺改革（高成本，org−0.45，stage−1） | 逮捕领袖（需驻军，org−0.35，失败 org+0.20） | 戒严（需驻军，org−0.25，当地满意度−） | — |
| 4 叛乱 | 举旗 | 招安（极高成本，成功率最高，链终结） | — | 镇压（需驻军，失败→独立） | 弃城（保军队，失地块，仍宣战） |

**文案与数值分离**：事件正文由内容作者按 `project-keynes-narrative-event-writing` 的口径写（文学场景 + 2–3 选项 + 结果分支），数值只引用 `target_key`/`int_value`，不在正文里写死百分比。现有内容正文平均 150 字、选项 4–16 字，新链保持一致。

**成功/失败结算表**（Δorg 以 0–1 为单位；`trauma` 是镇压后遗症，抬高后续 `capacity`）：

| 行动 | 成本 | 成功 Δorg | 失败 Δorg | 失败附加 |
| --- | --- | --- | --- | --- |
| 让步·减免赋役（1 阶） | 中（现金） | −0.25 | +0.03 | 阶段前进，trauma+0.03 |
| 让步·公开谈判（2 阶） | 中高（现金） | −0.35，stage−1 | +0.05 | 阶段前进 |
| 让步·承诺改革（3 阶） | 高（现金+修正） | −0.45，stage−1 | +0.05 | 阶段前进 |
| 收买·召见头面人物（1 阶） | 小（现金） | −0.15 | +0.05 | 影响力−10% |
| 收买·分化（2 阶） | 中（现金） | −0.30 | +0.10 | 影响力−15% |
| 镇压·斥责/拘押（1 阶） | 免费 | −0.05 | +0.10 | trauma+0.05，家族 backing− |
| 镇压·驱散（2 阶） | 驻军 | −0.20 | +0.15 | trauma+0.08，当地满意度− |
| 镇压·逮捕/戒严（3 阶） | 驻军+现金 | −0.35 | +0.20 | trauma+0.12，家族 backing− |
| 无视 | 0 | — | +0.08 | `next_check_day` 提前 50% |
| 招安（4 阶） | 极高（现金+修正） | −0.60，链终结 | 独立 | — |
| 镇压（4 阶） | 驻军 | −0.70，链终结 | 独立 | 驻军损失 20–40% |
| 弃城（4 阶） | 0 | 链终结，失地 | — | 独立+战争 |

`cost_bonus` 与花费挂钩：`+min(0.25, spend / reference_cost × 0.15)`，`reference_cost` 按地块人口与阶数配置；超过参考成本 1.7 倍后不再加成功率（避免"钱能买一切"）。

**示例（第 4 阶开头，供风格校准）**：

> 天没亮，城门口的火把已经排成一条线。铁匠铺的炉子昨夜就熄了，街上没有叫卖，只有脚步声。有人把一面旧旗挂在市集的秤杆上——那不是哪一家的旗，是去年修渠时各家凑布缝的。
>
> 领头的不是生人。他是替你们家打了二十年铁的师傅，去年冬天还在为官府修城门。
>
> 他要求的不多：把今年的丁税免了，把仓里那批发霉的谷子换掉，再放了三年前抓走的那两个人。

选项（示例）：

- 「开仓，免今年丁税」——花钱，成功率高，但其它城市会看着。
- 「让驻军进城，抓为首者」——驻军强则成，弱则全城反。
- 「带兵退出城，让这座城自己过」——失地，不失人。

### 3.6 独立与战争

```text
[链 4 阶，镇压失败 / 玩家弃城]
  ├─ country.create_country(stable_id, name, cell)        # 一次批次，原子抢格
  ├─ [可选] country.transfer_territory(neighbor_cell, rebel_handle) ×0–2
  ├─ military.declare_war(player_country, rebel_country)  # 玩家发起，需有兵
  ├─ native: 叛军驻军/叛军部队生成；该格 org 记录转移或清零
  ├─ narrative: 事件结果文案 + 编年史 + 全国告警
  └─ UI: 新国家配色/名字；边境重绘；战争面板出现
```

设计细节：

- **国名生成**：`<地块名> + <政权后缀>`（如「××公社」「××军政府」「××自由市」），按职业/时代选后缀；避免"叛军1"。`create_country` 需要唯一 `stable_id` 与非空显示名。
- **战争目标**：叛军国的战争目标就是守住该格；玩家可以镇压/和谈/承认。和谈即承认独立（`peace`），吞并即收复。
- **传染**：只传染给相邻、同职业、`org ≥ 0.6` 的格，最多 2 格；被传染格跳过事件直接入链 3 阶（给玩家反应时间）。
- **玩家亡国**：失去最后一格时 `country_last_territory_protected` 会拒绝批次。必须在事件层先判定"这是最后一格"，走 game over/流亡，而不是发一个注定失败的建国命令。
- **起始格**：玩家身份**每条命令**都从起始格重解析（`player_controller.gd:1647-1662`）。若起始格独立，下一条命令就会操作叛军国——这不是"读档才出问题"，而是**立即错乱**。M3 必须二选一：
  - 把玩家国家句柄持久化进 `player_view`，命令路径不再反推；
  - 或规定起始格不可独立（叛乱在起始格止步于"示威"），并在 UI 说明。

### 3.7 与现有系统的边界

- **社会压力事实（type 8）**：继续保留，作为"体感温度"；组织度不发同类事实，避免两条不满流。可在 UI 上把两者合并成一个"民情"面板。
- **`_cell_social_pressure_level`**：不改语义。组织度用它做 `local_sat` 的参考，不写回。
- **家族**：只读 `prestige_level / influence_score / satisfaction`，不写家族状态。若要让家族"表态"，另立 `family_loyalty`，不要塞进组织度。
- **Modifier**：让步可用现有 `economy.city.need.<need>.consumption_factor`（cell-scope，真实存在）表达"平粜/赈济"；**不要**假设有 `economy.city.satisfaction_bp`（当前不存在，城市 stat 族只有 need/good/building/resource/birth）。全国×职业的 `economy.profession.<pid>.satisfaction_bp` 也不能表达"本地让步"。
- **Ideology**：不新增阶层立场；`class_influence` 只作为事件档位的加成输入。
- **Military**：不接管战斗；叛乱成功后的"战争"仍是 Military 的普通战争，叛军国按普通 AI 国家运行（若 AI 不接管新国家，需要最小守成逻辑）。

### 3.8 存档、确定性、性能

**存档**：PKEC schema 61 → 62，新增 `SAVE_SECTION_STRATUM_MOBILIZATION`（稀疏行），字段见 §3.2。

- 严格校验：`cell < cell_count`、`profession < profession_count`、Q16 范围、`stage ≤ 4`、日期单调。
- 进 `state_hash`；旧档明确拒绝（项目政策：开发期不做隐式迁移，[current-state.md:262](../architecture/current-state.md)）。
- 若 M0 只做只读查询，可先不升 schema；M1 落状态时必须升。
- 先对齐 §0.1 第 5 项的 60/61 漂移，再动版本号。

**确定性**：

- 触发与结算用 `hash64(world_seed, day, cell, profession, stage, salt)`，与 `NarrativeRng` 同构；不保存 RNG 状态。
- 所有输入取**最近一次已提交**的满意度/份额；不读 plan，不读未提交 epoch。
- 叙事层参与掷骰时，salt 必须用 `(chain_id, stage, day, cell, option)`，**不要用 `offer_id`**（§1.6）。

**性能**：

- 默认地图 60×40 = 2400 格（[world_runtime_host.gd:67](../../Project/project-keynes/scripts/world_runtime_host.gd)），桌面允许 500×400（`world_setup.gd:34-35`），Web 100×70。
- 每格平均 4–8 个 cohort（旧归档 1166 格约 6700 cohort → 5.7/格），按职业聚合后 2–5 行。全球 5k–15k 行。
- 每日一次稀疏循环：~10k × 20 次定点运算 ≈ 0.2M 次，远低于经济现有热循环（`j_economy_daily_ms` 2.5–3.4ms 量级，[satisfaction-runtime.md:288-294](../cpp-dots-runtime/satisfaction-runtime.md)）。
- 满意度聚合复用结算循环（`for_each_in_cell` 已在跑），**不新增全世界 cohort 扫描**。
- `garrison_heads_at` 是全表扫描：只在**有活跃链的格**上调用（全国 ≤3 条），不要每格每日扫。
- 事件查询是冷路径（玩家点开某一格/某一事件时），单格 O(cohort)，可接受。

**不新增日域**：`RuntimeDomainId` 变更会改 ABI（[development-guide.md:152](../architecture/development-guide.md)）；组织度作为 Economy 内部状态，在既有 `ECONOMY` 阶段内推进。

### 3.9 UI 与可读性

按 `project-keynes-ui-development` 的验收口径，分三层：

1. **地图层**（复用 `cell_situation_layer.gd` 的告警图标）：新增 `situation.mobilization` 图标，按 4 档变色；只在 **org ≥ 0.25** 时出现，避免全图噪声。
2. **地块档案页**：新增「民情」小节，列出本格各职业的：组织度条、链阶段、趋势（↑/→/↓）、最差维度、影响力占比。页头四格加一个「离心」指标（本格最高 org）。
3. **事件弹窗**：每个选项显示
   - 成功率（来自 native 查询，与结算同一函数）；
   - 成本（现金/货物/驻军调动）；
   - 失败后果（org +、阶段前进、trauma）；
   - 加数明细（驻军 +18%、家族 +9%、当地民心 +12%、组织度 −35%）。

**预警原则**：玩家在 org 0.25 就能看到"这座城在攒事"；0.30 触发第一阶事件。不允许"组织度 0.8 才第一次出现"的突袭式设计。

**弹窗代价**：叙事弹窗会暂停时钟并锁住其它命令，且没有超时/忽略（§1.6）。四阶链最多 4 次弹窗；必须限制全国同时链数，否则会变成"弹窗连环锁"。

---

## 4. 实施计划

### M0：只读地基（2–3 天）

- [ ] 新增 `query_cell_stratum_mobilization(cell)`：返回本格各职业的 `share / satisfaction / influence / org(只读 0)`。
- [ ] 地块档案页「民情」小节（只读，无状态）。
- [ ] 修复叙事采样的 `satisfaction` 默认值问题（§0.1 第 1 项）：让 `population_cell_summary` 返回 composite，或在采样器里直接读 `get_cell_satisfaction_attractiveness`。
- [ ] 不升 schema、不改 ABI、不写状态。
- 验收：任意格能读到 2–5 行职业数据；无新存档段；性能不回归。

### M1：组织度状态（3–5 天）

- [ ] `StratumMobilizationStore` + 每日稀疏推进 + `s_ema` + 人口份额聚合。
- [ ] 存档段（PKEC v62）+ `state_hash` + 旧档拒绝 + 契约 JSON。
- [ ] 地图告警图标 + 档案页趋势。
- 验收：饥荒/重税格 org 在 30–60 天内可见上升；和平格回落；存读档逐日一致。

### M2：事件链（4–6 天）

- [ ] native：`query_rebellion_odds`、`resolve_rebellion_action`、事实发布、stage 状态机。
- [ ] 叙事：4 阶 × 3 选项 + 成功/失败分支 + 后续排程 + 冷却；链结束时取消排程。
- [ ] 动态 outcome 概率（`choose_option` 按 ctx 调整权重）+ 稳定 salt。
- [ ] 成功率明细 tooltip。
- 验收：一条完整链可在 3–12 个月内走完；所有选项的成功率与 native 结算一致；读档不改变已选结果。

### M3：独立与战争（5–8 天，含 spike）

- [ ] spike：运行中 `create_country` + `declare_war` 的跨域完整性（Economy/Ideology/Military 国家表、槽位漂移）。
- [ ] 最后一格/起始格/玩家身份改绑的显式处理；game over 或流亡。
- [ ] 修割地驻军转移 no-op；叛军驻军/部队生成；叛军国最小 AI。
- [ ] 国名生成、配色、UI。
- 验收：成功叛乱后该格脱离、新国家出现在地图/外交/战争面板、战争可打可和；读档后仍一致。

### M4：平衡与内容（持续）

- [ ] 职业变体（军人、商人、矿工、佃农）。
- [ ] 长跑校准（`economy_balance_soak.gd` + 新指标）。
- [ ] 与年度报告、编年史、成就联动。

---

## 5. 风险与决策点

### 5.1 风险

| 风险 | 可能性 | 影响 | 缓解 |
| --- | --- | --- | --- |
| 新国家跨域簿记不完整（Economy/Ideology/Military 越界或跳过） | 中 | 高 | M3 前 spike；失败则降级为无主格 |
| Military 槽位与 Country 槽位漂移（`handle==0` 跳过 + 槽不复用） | 中 | 高 | 建国/灭国专项测试；必要时改成按 handle 查询 |
| 满意度离散结算导致 org 抖动 | 高 | 中 | `s_ema` + 稳态模型；只读已提交值 |
| 早期/贫困格常年叛乱 | 中 | 高 | 阈值落 0.45–0.5；按长跑校准；每国链上限 |
| 事件洪水/弹窗连环锁 | 中 | 中 | 1 链/格、全国 ≤3、冷却 180–240 天、阶段 1 只做轻量提示 |
| 成功率"显示与结算不一致" | 中 | 高 | 同一 native 函数出概率与结算；UI 不重算 |
| 读档改变已定结局 | 中 | 中 | 稳定 salt；结果入链状态 |
| 镇压无代价（玩家总选镇压） | 中 | 中 | trauma 累积、家族 backing 下降、当地满意度下降、驻军损耗 |
| 叙事排程不复查条件，链结束后又弹 | 中 | 中 | 链结束时显式取消排程；到期由 native 复核 stage |
| 玩家身份由起始格反推，起始格独立导致改绑 | 低 | 高 | 存 player handle；独立前判定 |
| 存档 schema 升级使旧档失效 | 高 | 低 | 开发期政策已如此；在版本说明里写清 |

### 5.2 需要拍板的决策

1. **只做玩家国家，还是 AI 也参与？** 建议 v1 只做玩家国（AI 只累积、不弹窗、不独立），避免 AI 世界被随机打碎。
2. **"独立"是否必须新建国家？** 若能接受"无主格 + 叛军武装"，M3 风险降一个数量级。
3. **"职业影响力"用本地人口份额，还是叠加全国政治影响力？** 建议主用本地份额，全国影响力只调档位。
4. **家族"支持"用满意度代理，还是新做 `family_loyalty`？** 建议先代理，并在 UI 明确口径。
5. **失败是否可逆？** 独立后玩家能否通过战争收复、和谈承认、或长期经营同化？
6. **数值风格**：组织度是"可见的慢变量"（推荐），还是"事件驱动的一次性判定"？
7. **是否接受 PKEC schema 升级与旧档失效？**
8. **"叛军宣战"还是"朝廷讨伐"？** 前者需要给叛军生成驻军并改宣战门槛；后者只需玩家发起战争，语义弱一档但零 native 改动。

---

## 附录 A：关键代码位置

| 主题 | 位置 |
| --- | --- |
| cohort 满意度列 | `gdext/src/runtime_economy_population_store.h:44-50` |
| 满意度公式与八维 | `docs/cpp-dots-runtime/satisfaction-runtime.md` |
| 满意度写入与偏置 | `gdext/src/economy_runtime_satisfaction.cpp:227-446` |
| 地块阶层聚合（冷路径） | `gdext/src/economy_runtime_queries_situation.cpp:60-118` |
| 地块满意度聚合 | `gdext/src/economy_runtime_queries_market_building.cpp:406-467` |
| 社会压力事实 | `gdext/src/economy_runtime_events.cpp:168-227` |
| 市场周期 1–5 天 | `gdext/src/economy_runtime.h:245-246` |
| 职业→政治阶层 | `gdext/src/economy_runtime_carrying.cpp:384-401` |
| 阶层影响力公式 | `gdext/src/ideology_runtime.cpp:1357-1366` |
| 家族威望/满意度/评审 | `gdext/src/economy_runtime_lineage_lifecycle.cpp:560-707`、`docs/cpp-dots-runtime/notable-family-runtime.md:84-101` |
| 驻军查询 | `gdext/src/military_core.h:1054`、`gdext/src/military_core_war.cpp:1116-1126` |
| 地块军事快照 | `gdext/src/world_ext_military.cpp:2986-3092` |
| 宣战命令 | `gdext/src/military_core.h:734`、`gdext/src/military_core_war.cpp:407-435` |
| 建国/割地命令 | `gdext/src/country_api.h:69-118`、`gdext/src/country_core_apply.cpp:366-517` |
| 最后一格保护 | `gdext/src/country_runtime.cpp:4240-4245` |
| 叙事定义/选项/结果 | `Project/project-keynes/scripts/narrative/narrative_event_definition.gd`、`narrative_option.gd`、`narrative_outcome.gd` |
| 叙事条件/效果 | `narrative_condition.gd:4-56`、`narrative_effect_spec.gd:7-24` |
| 叙事 RNG | `narrative_rng.gd:14-33` |
| 叙事节奏/排程/掷骰 | `narrative_event_service.gd:24-35,399-428,1309-1317` |
| 叙事弹窗与暂停 | `narrative_event_flow.gd:103-130,186-194` |
| 叙事采样满意度 | `narrative_context_sampler.gd:299-312` |
| 玩家身份反推 | `scripts/game/world_runtime_visual_adapter.gd:444-460` |
| 存档段清单 | `docs/architecture/current-state.md:274-287` |

## 附录 B：命名与口径约定

- 代码里 `mobilization` = 社会"组织度"；`organization` 只指军事部队组织度。
- UI 里"满意度"一律是人口加权 composite（[satisfaction-runtime.md:267-277](../cpp-dots-runtime/satisfaction-runtime.md)）。
- "当地满意度"默认指**排除起事阶层**的影响力加权值，UI 必须标注"不含起事者"。
- "职业人口份额"是 `Σ cohort.population / cell.population`，**不是** `cell_profession_share_q16`（后者是就业份额）。
- "高威望家族"默认 `prestige_level ≥ 4`（≥20% 档）。
- 所有概率以 Q16 存储，UI 显示整数百分比；低于 1% 显示"<1%"，高于 99% 显示">99%"。

## 附录 C：不做的事

- 不为组织度新增第十三个日域。
- 不在 GDScript 里重算满意度或组织度公式。
- 不把 `organization` 这个名字用于社会组织度。
- 不使用 `economy.profession.*.satisfaction_bp` 表达"本地让步"（它是全国×职业，不是地块级）。
- 不把家族支持写成"满意度够高就永远支持"；必须有威望权重与负值区间。
- 不让叛乱事件绕过冷却与全国上限；宁可少弹，不可刷屏。
- 不依赖叙事排程的"到期自动触发"来做链推进；到期必须由 native 复核 stage 后再决定。
