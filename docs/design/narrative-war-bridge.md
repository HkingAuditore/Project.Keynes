# 战争 × 叙事事件：桥接与内容

> 结论：军事运行时一直在往 `GameplayEventBus` 推六种战事事实，但事件库里只有一条事实驱动事件、且与战争无关；也没有任何战争条件。这次把「读军事快照」与「消费战事事实」两条路都接上，并写了 15 条事件（12 条孤立 + 3 节家族从军链）。

- 代码：`narrative_event_catalog_war.gd`、`narrative_context_sampler.gd`、`narrative_condition.gd`
- 事实来源：`GameplayEventBus`（类型 40–45）、`MilitaryFacade.country_snapshot`
- 测试：`tests/game/narrative_war_bridge_test.gd`

---

## 1. 现状审计

| 层 | 之前 | 现在 |
| --- | --- | --- |
| 事实入口 | `narrative_event_service` 已映射 40–45，但事件库只有一条事实事件（类型 8，社会压力） | 战争包 6 条，按 40–45 各一条 |
| 条件 | 没有任何战争/军事算子 | `AT_WAR`(45)、`SOLDIERS_TOTAL_GTE`(46)、`WAR_GOING_BADLY`(47) |
| 采样 | `sample_country_context` 不读军事门面 | 读一次 `country_snapshot`，填 8 个字段 |
| 内容 | 无战时事件 | 6 条事实 + 6 条脉冲 |
| 状态探针 | 3 条（粮价、不满、连旱） | +2 条（战时后方、战败阴影） |

## 2. 军事快照契约（已核实）

`MilitaryFacade.country_snapshot(country)` → `get_military_country_snapshot`：

| 字段 | 语义 |
| --- | --- |
| `soldiers_total` / `soldiers_militia` / `soldiers_trained` | 兵员总数与构成 |
| `soldiers_garrisoned` / `soldiers_in_armies` / `soldiers_training` | 驻扎、随军、在训 |
| `wars` | 进行中的战争数组；每条含 `war_id`、`attacker_slot`、`defender_slot`、`start_day`、`score_q16`、双方损失、`fully_occupied` |
| `wars_active` | 战争条数 |

**注意**：

1. `score_q16` 是**攻方视角**的合成分（会战 + 歼灭 + 消耗）；守方读到的符号在原生侧已翻转，叙事只看“最差一场是否 ≤ −0.5”。
2. 快照是**国家视角**，不告诉你“这一格是不是前线”。前线需要 `cell_snapshot`，这一批不做。
3. `wars_active == 0` 不代表和平刚发生——事实 41 才是“刚结束”的信号。

## 3. 采样字段（`sample_country_context`）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `military_available` | false | 门面可用且快照 ok |
| `at_war` | false | `wars_active > 0` |
| `war_count` | 0 | 战争条数 |
| `wars` | [] | 原始数组，留给后续“具体战场” |
| `soldiers_total` | 0 | 兵员总数 |
| `soldiers_in_armies` | 0 | 随军人数 |
| `war_score_min_q16` | 0 | 各场 `score_q16` 的最小值 |
| `war_losses_total` | 0 | 各场双方损失之和 |

成本：每次国家采样一次 committed read；国家采样在每次事件报价/事实批次时发生，不在每格扫描里重复。

## 4. 三个条件

| op | 名称 | 参数 | 语义 | 无军事数据 |
| --- | --- | --- | --- | --- |
| 45 | `AT_WAR` | `bool_value` | 是否有进行中的战争 | false |
| 46 | `SOLDIERS_TOTAL_GTE` | `int_value` | 兵员总数 ≥ N | false |
| 47 | `WAR_GOING_BADLY` | `bool_value` | 任一场 `score_q16 ≤ -0.5` | false |

`AT_WAR false` 可用于“战后”类事件；`WAR_GOING_BADLY` 只表达“在打且打得差”，不与 `AT_WAR` 重复。

## 5. 事实驱动（6 条）

`trigger_channel = FACT_DRIVEN`，`fact_event_type` 对应：

| 类型 | 事实 | 事件 | 门槛 |
| --- | --- | --- | --- |
| 40 | 宣战 | `war.declaration` | 在战、人口 ≥ 8 |
| 41 | 战事结束 | `war.victory` | 不在战、人口 ≥ 8 |
| 42 | 会战分出胜负 | `war.battle` | 人口 ≥ 8 |
| 43 | 城池易手 | `war.city_taken` | 人口 ≥ 8 |
| 44 | 部队被歼 | `war.army_lost` | 人口 ≥ 8 |
| 45 | 国家被吞并 | `war.annexed` | 人口 ≥ 8 |

事实路径的规则（与代码一致）：

- `trigger_chance_q16` 决定命中；`evaluate_event_weight` 仍会跑一遍条件与冷却，权重 ≤ 0 就跳过。
- 一次事实批次最多弹一条（`return`），避免战事刷屏。
- 事实事件也吃全局弹窗间隔闸门。

## 6. 战时脉冲（6 条）

| id | 标题 | 门槛 | 主题 |
| --- | --- | --- | --- |
| `war.conscription` | 征丁 | 在战、人口 ≥ 10 | 抽丁与买免 |
| `war.arrears` | 欠饷 | 在战、兵 ≥ 100 | 补发 / 白条 / 裁撤 |
| `war.wounded` | 伤兵 | 在战、兵 ≥ 150 | 收容 / 遣返 / 只留能治的 |
| `war.refugees` | 城下的人 | 在战、人口 ≥ 12 | 开门 / 城外设棚 / 不放 |
| `war.army_market` | 军市 | 在战、商人 ≥ 2% | 官营 / 包商 / 取缔 |
| `war.aftermath` | 战后 | 不在战、人口 ≥ 12 | 抚恤 / 垦荒 / 追欠税 |

## 6.5 家族从军链（3 节）

| 节 | id | 入口 | 关键效果 |
| --- | --- | --- | --- |
| 1 | `war.kindred_levy` | 脉冲（在战 + 族威望 ≥ 2） | 选“出人”才置 `flag_war_kindred_sent` 并排程 150 日后的家书 |
| 2 | `war.kindred_wait` | 排程 + 读取该 flag | 三条分支：阵亡（置 `flag_war_kindred_dead` 并排程立祠）／生还／无消息 |
| 3 | `war.kindred_shrine` | 排程 + 读取阵亡 flag | 刻名（授 `j020_gentry`）／不立祠／只记族谱 |

这条链是家族桥与战争桥的第一次合流：门槛同时吃 `AT_WAR` 与 `FAMILY_PRESTIGE_GTE`，
效果同时用家族特质与通用经济杠杆；flag 在第二节全部清理，不会留下永久脏标记。



这一批**不写军事状态**：不改兵员、士气、补给、战争分数。所有效果仍是通用杠杆：

- 现金：`cash_in` / `cash_out`（落在本地人数最多的 cohort，不是军队）
- 实物：`staple`、`supply`（军粮）
- 产出：农业/制造、建设成本、贸易容量
- 人口：出生
- 权重：动荡、宫廷、劳工

如果以后要“真的改军队”，需要给叙事效果加军事命令（征兵/补员/改预算），那是第二座桥。

## 8. 状态探针（+2）

| state_id | 条件 | 用途 |
| --- | --- | --- |
| `state.war.homefront` | 在战 + 最不满 ≤ 0.5 + 人口 ≥ 8 | AI 预取“战时后方”稿件 |
| `state.war.defeat` | 战败 + 人口 ≥ 5 | AI 预取“战败阴影”稿件 |

探针只影响 AI 生成入口，不影响静态事件触发。

## 9. 测试

`tests/game/narrative_war_bridge_test.gd` 15 项：

- 国家快照 → 8 个字段（含多场战争的分数最小值、损失求和）；
- `AT_WAR` 战时/战后、`SOLDIERS_TOTAL_GTE`、`WAR_GOING_BADLY`；
- 无军事门面/快照失败 → 默认值与条件 false；
- 探针目录含两条战争状态。

契约测试另加：54 条事件全部纳入 web 契约，`_is_entry` 把事实通道也算 entry（否则事实事件会被误判为“无入边”）。

## 10. AI 生成侧的上下文（2026-11-12）

`narrative_ai_prompt_builder` 的用户提示词新增三段快照，AI 事件因此能落到具体的人与事：

- **本地最大族**：族名、人口占比、威望档、拥有建筑、名人、门风（取前 4 个中文特质名）；
- **战事**：在战/未战、战争场数、兵员、随军、最差战果、累计损失；
- **已掌握科技**：节选前 10 个科技 id。

同时给 system prompt 加了第 7 条：有族/有战事时，事件必须写具体的人与代价，不许只写“民心不稳”。

`narrative_ai_validator` **不需要改**：它只校验 JSON 形状、效果白名单与读数禁令，
`tags` 是自由字符串（没有白名单），family/war 类标签可原样通过。

## 11. 风险与后续

1. **类型 45 的发射依赖吞并条约路径**：如果某局只打到附庸、不吞并，45 不会来；这是事实源的问题，不是事件的问题。
2. **快照是全国视角**：事件只能写“国中某城”，不能写“这座城就在前线”。要写前线，得读 `cell_snapshot` 并在采样器里加格级军事字段。
3. **事实事件的条件在格上下文上求值**（国家字段已合并），所以 `AT_WAR` 可用；但 `wars` 数组不参与文案，避免把内部 id 写进文本。
4. 下一步可做：和谈条款事件（读 `propose_peace` 的条款）、围城事件（读 `cell_snapshot` 的 control/threat）、军队过境事件（读 armies 的路径）。
