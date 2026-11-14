# 叙事事件扩展手册（小说笔法 · 地块上的人 · 世界内典故）

本文服务一个具体问题：**不改引擎，把现有触发条件、权重与效果设计用满，写出有文学质感、能让人看见「地块上的人」的事件。**

配套资产：

| 资产 | 位置 |
| --- | --- |
| 水利工程链（4 幕，可直接跑） | `scripts/narrative/narrative_event_catalog_waterworks.gd` |
| 地块上的人（2 幕，可直接跑） | `scripts/narrative/narrative_event_catalog_people.gd` |
| 契约测试 | `tests/game/narrative_event_waterworks_chain_test.gd`、`tests/game/narrative_event_people_test.gd` |
| 运行时与文案规范 | `docs/cpp-dots-runtime/player-controller-runtime.md`（叙事事件章节） |
| 计量规则（修饰器） | `scripts/modifier/modifier_catalog.gd`、`gdext/src/modifier_runtime.cpp` |

---

## 0. 先记住四条

1. **触发三通道各管一段**：`PULSE_SAMPLED` 管日常局势，`FACT_DRIVEN` 管刚发生的事，`SCHEDULED_ONLY` 管因果后续。
2. **效果键分两族，`magnitude_q16` 语义不同**：`economy.city.good/building.*` 传「幅度本身」，`family.city.*` 只放大内置的 2~5%。混用的代价是三到八倍偏差。卡面数字一律手写 `custom_label`。
3. **定时事件不看条件、不看标记**：分支要靠「排不同的 event_id」，标记只对脉冲通道生效。
4. **写场景，不写摘要**：正文里要有一个具体的人、几件具体的物件；不要「某某说：『……』」的引语块，
   也不要用一句总结代替画面。读者记不住 +15%，但记得住王三那把没带走的铁锹。

---

## 1. 四个杠杆

| 杠杆 | 字段 | 你实际能控制什么 |
| --- | --- | --- |
| 何时出现 | `trigger_channel` / `fact_event_type` / `conditions` / 科技·时代门槛 | 在哪个地块、哪种局势、哪个时代出现 |
| 多常出现 | `base_weight` / `weight_rules` / `trigger_chance_q16` / `cooldown_days` / `one_shot` / `scope` | 同一局势下的相对概率，以及重复出现的间隔 |
| 出现后改什么 | `options[].outcomes[].effects`（15 种 `Kind`） | 修正、守恒转移、科研线索、叙事状态、后续排程、概率偏置、家族特质 |
| 留下什么 | `SET_STORY_FLAG` / `CLEAR_STORY_FLAG` / `ADD_EVENT_WEIGHT_BIAS` / `SCHEDULE_FOLLOWUP_EVENT` | 跨事件的因果、状态与「同一批人的下一幕」 |

### 1.1 触发通道

| 通道 | 何时评估 | 适合什么 | 例子 |
| --- | --- | --- | --- |
| `PULSE_SAMPLED` | 每 `pulse_interval_days`（20 日）抽样 1~8 个领土地块 | 环境 × 经济 × 人群的长期局势 | 旱灾、渔汛、开渠、城门外的人 |
| `FACT_DRIVEN` | `GameplayEventBus` 事实到达时（天气锋面 3、营造完工 6、商队 7、民生压力 8、科研线索 9、地貌发现 10、技术采纳 13、军事 40–45） | 「刚发生」的即时反应 | 商队入港、城池易手 |
| `SCHEDULED_ONLY` | 只由 `SCHEDULE_FOLLOWUP_EVENT` 排程触发 | 因果后续、多幕剧、善后 | 通水、半条渠、粥棚撤了 |

### 1.2 条件算子（`NarrativeCondition.Op`，48 个）

| 维度 | 算子 | 数据来源 |
| --- | --- | --- |
| 气候 | `TEMP_GTE/LTE`、`MOISTURE_GTE/LTE`、`PRECIP_GTE/LTE`、`SNOW_GTE` | 地块气候场（日均） |
| 地理 | `ELEVATION_GTE/LTE`、`HAS_RIVER`、`IS_COASTAL`、`OCEAN_CURRENT_SPEED_GTE`、`OCEAN_UPWELLING_GTE`、`TERRAIN_IN`、`LANDFORM_IN`、`VEGETATION_IN` | `MapData` + 邻接水格 |
| 人口 | `POPULATION_GTE/LTE`、`SATISFACTION_GTE/LTE` | 聚落人口与合成满意度 |
| **人群** | `SUBSISTENCE_SHORTFALL_GTE`、`UNEMPLOYMENT_GTE`、`PROFESSION_SHARE_GTE`、`COHORT_SATISFACTION_LTE` | cohort 明细表（见 1.4） |
| 经济 | `HAS_BUILDING_TYPE`、`BUILDING_COUNT_GTE`、`MARKET_GOOD_SHORTAGE`、`MARKET_GOOD_STOCK_GTE/LTE`、`MARKET_GOOD_PRICE_RATIO_GTE`、`HAS_NATURAL_RESOURCE` | `EconomyFacade` 当日快照 |
| 国家 | `TREASURY_CASH_GTE/LTE`、`HAS_TECHNOLOGY`、`LACKS_TECHNOLOGY`、`ERA_GTE/LTE` | `CountryFacade` |
| **家族** | `HAS_NOTABLE_FAMILY`、`FAMILY_PRESTIGE_GTE`、`FAMILY_POP_SHARE_GTE`、`FAMILY_OWNS_BUILDINGS_GTE`、`HAS_FAMILY_TRAIT` | `family_cell_snapshot` + `get_family_traits`（本格最大族） |
| **军事** | `AT_WAR`、`SOLDIERS_TOTAL_GTE`、`WAR_GOING_BADLY` | `MilitaryFacade.country_snapshot`（本国） |
| 叙事 | `HAS_STORY_FLAG`、`LACKS_STORY_FLAG`（条件）+ `required_story_flags` / `blocked_story_flags`（定义级） | `pknr` 持久化标记 |

组合原则：**一条事件用 3~4 个维度足够**。全是地理条件会变成「地形彩蛋」，全是经济条件会变成「数值汇报」。
示范里开渠同时用河流（地理）+ 平原（地形）+ 偏干（气候）+ 人口（社会）+ 灌溉科技（国家）；
城门外的人则只看人群：严重入不敷出人口占比 + 人口，再用失业、粮价、最不满群体抬权。

### 1.3 权重与节奏

- `base_weight` 是基准；`weight_rules` 按条件加权重（`add_weight`）再乘倍率（`multiplier_q16`，1.3x = 85197）。运行时最终权重 = `(base + Σadd) × Πmul`。
- `ADD_EVENT_WEIGHT_BIAS` 是**跨事件**的权重偏置：按 `tag_key` 或 `target_event_id` 生效，是「经历 A 之后 B 更容易出现」的唯一实现方式。饥民被赶走后抬 `unrest` 类事件的权重，就是这条。
- 节奏常量（`narrative_event_service.gd` 头部）：脉冲 20 日一次、单次放行 25%、全局弹窗间隔 60 日、每格每年 2 次。**写链式内容时不必担心额度**：`SCHEDULE_FOLLOWUP_EVENT` 走 `bypass_gap`，不占格年额度、不受 60 日闸门限制。
- `one_shot` 只拦脉冲通道；定时事件重复排程仍会重复触发，所以「只此一次」的收束幕也要只排一次。

### 1.4 人群上下文（让事件写得出「谁」）

`NarrativeContextSampler` 在取 cohort 明细时会多算出一组人群事实，条件与文本都能用：

| 字段 | 含义 | 可写的题材 |
| --- | --- | --- |
| `primary_cohort_profession_name` | 人数最多的那一群的职业名 | 效果标签写清「钱给了谁」 |
| `neediest_cohort_*` | 满意度最低的那一群 | 怨气从哪来 |
| `subsistence_shortfall_population` / `_ratio` | 生计覆盖率 < 0.5（且非全员失业）的人口与占比 | 饥荒、逃户、赈济 |
| `unemployed_population` / `unemployment_ratio` | 失业人口与占比 | 流民、工赈、治安 |
| `profession_population_by_id` / `profession_share_by_id` | 各职业人口与占比（stable id） | 渔村、盐户、匠户、商埠 |
| `dominant_profession_id` / `_name` / `_share` | 占比最高的职业 | 正文里直接点出「这座城多半是农户」 |

取明细有成本，所以只在需要的地方打开：脉冲 / 事实 / 状态探针扫描传 `include_cohort_details=true`；
`enqueue_event_offer` 仍走汇总（入队不取明细的契约由 `narrative_event_runtime_test.gd` 守着）。

---

## 2. 效果：15 种 `Kind` 与它们的真实语义

### 2.1 种类速查

| `Kind` | 作用 | 守恒？ | 备注 |
| --- | --- | --- | --- |
| `CITY_MODIFIER` | 单城属性修正（按格 group） | 是（只改系数） | 主力量，见 2.2 |
| `COUNTRY_MODIFIER` | 全国属性修正（按国家 entity） | 是 | 见 2.3 |
| `TREASURY_CASH_TO_COHORT` | 国库 → 本地人数最多的那一群 | **守恒现金** | `ratio_bp` 或 `int_value`，按实时余额截断；标签用 `{primary_profession}` 写清职业 |
| `COHORT_CASH_TO_TREASURY` | 本地人数最多的那一群 → 国库 | **守恒现金** | 同上，方向相反 |
| `COUNTRY_GOOD_TO_MARKET` | 国库物资 → 本地市场 | **守恒物资** | 需要国库真有该物资 |
| `MARKET_GOOD_TO_COUNTRY` | 本地市场 → 国库 | **守恒物资** | 配合 `require_good_id` 做门槛 |
| `MARKET_ADD_STOCK` | 本地市场凭空增库存 | 否 | 用于「官仓出粮」这类外部流入 |
| `MARKET_REMOVE_STOCK` | 本地市场减库存 | 否 | 用于「征发 / 损毁」 |
| `DISCOVER_RESEARCH_SIGNAL` | 让该格发现一条科研线索 | 否 | `target_key` 必须是 `research_signal_ids` 里的 id（如 `bio.rice`） |
| `SET_STORY_FLAG` | 打标记（可带天数、可限格） | — | 脉冲通道的硬门槛来源 |
| `CLEAR_STORY_FLAG` | 清标记 | — | 用于「路线关闭 / 重启」 |
| `ADD_EVENT_WEIGHT_BIAS` | 按 tag 或 event_id 改后续权重 | — | 正负皆可（`int_value` −500..1000） |
| `SCHEDULE_FOLLOWUP_EVENT` | N 日后在本地块触发指定事件 | — | 定时事件直接入队，不看条件 |
| `GRANT_FAMILY_TRAIT` | 给本格最大族授一个特质 | — | `target_key` = 特质 id（如 `i005_knowledge`）；已存在则改强度，core 特质跳过 |
| `REMOVE_FAMILY_TRAIT` | 从最大族撤一个特质 | — | 只删非 core；无族/无 key 静默 simulated |

> 家族与战争是最近两座桥：家族效果只作用于**本格最大族**（快照第一条），不写家族现金/威望；
> 战争只读军事快照（`AT_WAR` / 兵员 / 战果），不写军队状态。契约分别见
> `narrative-family-bridge.md`、`narrative-war-bridge.md`。
> 技术包不新增 Kind：它用已有的 `HAS_TECHNOLOGY` 做门槛，让「先点哪门科技」改变能碰到的事。

### 2.2 单城修正：两族定义，两种语义

| 定义族 | 例 | 原生项 | `magnitude_q16` 的含义 | 实测 |
| --- | --- | --- | --- | --- |
| 生成族（推荐） | `economy.city.good.wheat_grain.output_factor`、`economy.city.building.agriculture_output_factor`、`economy.city.building.<building>.output_factor`、`economy.city.birth_factor` | ADD 1.0 | **幅度本身**：+25% → `_pct(25)` = 16384 | 1.25 ✓ |
| 生成族减益 | 同名 + `.cut` | SUBTRACT 1.0 | 幅度本身：−12% → `_pct(12)` | 0.88 ✓ |
| 手写族 | `family.city.agriculture_output_boost`、`family.city.production_boost`、`family.city.birth_cut` | MULTIPLY 1.02~1.05 | **只放大那 2~5%**：传 1.15 只得 +5.75% | 见 2.4 |

**结论**：新内容一律用生成族 + `.cut`，并把 `magnitude_q16` 写成 `_pct(目标百分比)`。手写族只适合「必须复用某个既有 buff 定义」的场合，且必须自己算清真实增幅。

消费维度同样可用且已实测：`economy.city.need.staple_food.consumption_factor` 传 `_pct(20)` 实测 1.20，
`.cut` 传 `_pct(10)` 实测 0.90。它是「让贫户吃得起饭」最直接的杠杆——会进入需求满足率，
进而影响满意度与死亡/出生。

### 2.3 全国修正：可用的只有少数几个

| 定义键 | 原生项 | 传什么 | 实测 |
| --- | --- | --- | --- |
| `country.economic_mobilization` | MULTIPLY 1.1 | 0.5 → +5%；1.0 → +10% | 1.05 / 1.10 ✓ |
| `ideology.country.output.<sector>_factor.gain` | MULTIPLY 2.0 | 幅度：+4% → `_pct(4)` | 1.04 ✓ |
| `ideology.country.trade.capacity_factor.gain` | MULTIPLY 2.0 | 幅度：0.1 → +10%（实测 1.10） | 同左 |
| `ideology.country.*.cost_factor.cut` / `population.death_factor.cut` | ADD 大额负值 | **政策级**，传 1.0 直接吃满（−60% 建设成本、−66.7% 死亡率） | 别当小额 buff 用 |

### 2.4 校准表：既有事件的卡面 vs 实测（历史对照）

> 下表记录的是**修正前**的旧写法。2026-11-11 起，旧 10 条事件已全部迁移到 ADD 族 / `_pct()`，
> 卡面与实测一致；保留此表是为了说明「为什么不能再用 `family.city.*` 手写百分比」。

用原生 `ModifierRuntime` 逐条实测（`tests/probes/probe_narrative_modifier_calibration.gd`），典型偏差：

| 卡面写法 | 定义键 | 实传 magnitude | 实测 |
| --- | --- | --- | --- |
| 本地农业产出 +15% | `family.city.agriculture_output_boost` | 75366 | **+5.7%** |
| 本地综合生产效率 +10% | `family.city.production_boost` | 72090 | **+2.2%** |
| 本地贸易产出 +20% | `family.city.trade_output_boost` | 78643 | **+6.0%** |
| 本地人口出生率 −20% | `family.city.birth_cut` | 52429 | **−2.4%** |
| 全国知识部门产出 +15% | `ideology.country.output.knowledge_factor.gain` | 75366 | **+115%** |
| 全国采掘部门产出 +15% | `ideology.country.output.extractive_factor.gain` | 75366 | **+115%** |

这不是示范引入的问题，而是「卡面百分比」与「magnitude 语义」两套约定混用造成的既有偏差：
手写族被压低 2~8 倍，全国 `.gain` 族被放大 8 倍。**两个内容包因此完全避开手写族，并给每条效果手写 `custom_label`**；
契约测试会把「标签百分比」与「原生实际乘数」逐条对比，防止再写错。

### 2.5 钱、粮、价、税：效果到底改了什么

写效果前先确认机制，别把「想要的结果」当成「已有的功能」：

| 常见说法 | 实际机制 | 应该怎么写 |
| --- | --- | --- |
| 国库转出资金 | 国库 ↔ **一个人群**（本地人数最多的那一群）的现金转移，守恒 | 「国库拨付本地人数最多的{primary_profession}，占国库现金 2.5%」 |
| 地方资金上缴 | 同一人群的现金 → 国库（不是全城所有人的财富） | 「向本地人数最多的{primary_profession}征收其现金的 1.5%」 |
| 官仓出粮 / 直接发粮给饥民 | 没有「物资直接发给人群」的效果。`MARKET_ADD_STOCK` 往本地市场增补库存（确定发生，但**要求该格有商人**，否则整批命令被拒），数量级要按人口口粮算（每人每日主食约 440 原始单位 = 0.44 单位）；`COUNTRY_GOOD_TO_MARKET` 需要国库真有货——而玩家无法收购物资，国库通常没有 | 「本地市场增补小麦 300 单位（官府调拨）」 |
| 发 6 单位小麦 | 实存可能只有 0.6，数量会被截断；写死数字会骗人 | 用比例（三成 / 四成），或写「至多 N 单位」 |
| 平抑 / 抬升粮价 | **没有**直接改价格的效果；价格仍由市场结算 | 不写价格结论，只写供需动作（投放 / 征调） |
| 减赋 / 抵扣赋税 | **没有**减税效果；税政在 Country 运行时 | 不写减赋；要补贴就写「国库 → 人群现金」 |

- 物资名一律走 `GoodProfileRegistry`（`NarrativeEffectSpec._friendly_good_name`），
  不要手写「麦粮」这种非游戏名——`wheat_grain` 的游戏名是**小麦**。
- 现金转移的收款人由 sampler 选出（人数最多的 cohort），标签用 `{primary_profession}` 占位，
  在入队与结算时填成真实职业名；`{dominant_profession}` 也可用。
- 想把钱给「最穷的那一群」：目前没有可读的收款对象，**不要写**。要么给人数最多的那群（标签写清职业），
  要么用 `MARKET_ADD_STOCK` 往本地市场增补实物（需该格有商人）。

### 2.6 接口有效性（2026-11-11 审计）

事件能用的接口不是都无条件生效，写之前先确认：

| 接口 | 真实约束 | 写法/替代 |
| --- | --- | --- |
| `SUBSISTENCE_SHORTFALL_GTE` / `UNEMPLOYMENT_GTE` / `PROFESSION_SHARE_GTE` / `COHORT_SATISFACTION_LTE` | 只在 `include_cohort_details=true` 的扫描里成立（脉冲/事实/状态探针）；入队与结算不取明细 | 只放在事件 `conditions`，不要放进选项门槛 |
| `TREASURY_CASH_TO_COHORT` / `COHORT_CASH_TO_TREASURY` | 只作用于**人数最多的那一群** cohort，不能指定职业 | 标签用 `{primary_profession}`；要指定职业需扩展 sampler/effect |
| `MARKET_ADD_STOCK` | 该格必须有商人，否则原生整批拒绝；数量按原始单位（每人每日主食约 440） | 事件条件加 `PROFESSION_SHARE_GTE merchant 0.001`；数量按口粮估 |
| `COUNTRY_GOOD_TO_MARKET` | 需要国库真有该物资；玩家不能收购物资，国库通常没有 | 正常游戏不要用；「官府出粮」用 `MARKET_ADD_STOCK` |
| `MARKET_GOOD_TO_COUNTRY` | 受本地市场实存截断；入库后没有面向玩家的用途（只能建造/时代晋升消耗） | 可以写「征调」，但别把它当奖励 |
| `require_good_id` / `require_good_qty` | 门槛把「本地市场 + 国库」相加；效果却只从各自来源扣 | 用 `COUNTRY_GOOD_TO_MARKET` 时门槛与效果不同源，容易「可选但空转」 |
| `DISCOVER_RESEARCH_SIGNAL` | target 必须是 `research_signal_ids` 里的 id，否则静默模拟 | 用目录里的真实信号 id |
| `SET_STORY_FLAG` / `CLEAR_STORY_FLAG` | 写入是真实持久化；但只有被 `required_story_flags` / `blocked_story_flags` / `HAS_STORY_FLAG` 读取才算机制 | 纯档案标记不要写进卡面期望 |
| `scope` | 只决定冷却键粒度（CELL/COUNTRY），不会把事件变成全国事件 | 跨格影响用 `COUNTRY_MODIFIER` 或全国修正 |
| `version` / `image_key` | 只做存档/档案元数据，运行时没有消费者 | 不要依赖它们改变 UI 或逻辑 |
| `{good_name}` | 解析「当前价格比最高的商品」，不是事件指定的商品 | 要写具体商品用 `{settlement_name}` 之外的固定文案 |
| `radius_cells` / `falloff`（仅 `CITY_MODIFIER`） | 只影响己方领土内、当前格 + 1~2 环的陆地；邻格列表由 sampler 写入 `nearby_owned_cells_r1/r2`，水面与外国格跳过 | `radius_cells: 2, falloff: 1` = 中心 100% / 1 环 60% / 2 环 30%；标签写「本地及周边 2 环……」 |
| `ADD_EVENT_WEIGHT_BIAS` | 同时给 `int_value` 与乘数会先加后乘；「权重」不等于「概率」 | 只给乘数，标签写「权重 ×1.5」 |

---

## 3. 文本怎么写：短篇小说，不是事件卡

### 3.1 三段式

| 层 | 字段 | 写法 | 反例 |
| --- | --- | --- | --- |
| 场景 | `body_text`（5~8 句） | 谁在做什么小动作，桌上有什么，光从哪儿来；让细节承担判断；最后落在必须决断的点 | 「本地农业面临减产。」 |
| 动作 | `options[].text`（4~16 字） | 动词 + 对象，能看出谁受益谁受损 | 「确认」 |
| 下场 | `outcome_title` + `outcome_narrative`（1~3 句） | 谁怎么了；结尾落在一个画面上 | 只有「+15% 农业」 |

**不要引语块。** 不再写「某某说：『……』」这种独立引语；需要说话时把话揉进叙述
（「他说，去凿吧」），或者干脆不写。`speaker` / `quote_text` 字段保留，但这两个内容包一律留空。

### 3.2 六个具体做法

1. **先给场景，再给判断**。不要写「农业面临减产」，写「河渠见了底，麦田裂成龟背」。让玩家自己得出「要减产了」。
2. **视角贴着一个人**。工程师跪在石板上，膝盖压着图；民夫蹲在渠边看水，先想工钱；守门的兵把门闩上，不敢开也不敢赶。
   一个具体的人，比十个形容词有用。
3. **用物件说话**。渠图被手汗浸软、名册念错的名字没人纠正、库房里的图压在一摞旧账本下面、铁锹插在土里没带走。
   物件比形容词可信。
4. **写一点社会关系里的算计**。谁在算粮、谁在拖时间、谁在等别人先开口、谁在背后给人起外号。
   这些细节让「人」立起来，也让选项的代价变得具体。
5. **结尾落在一个画面上**，不要总结。歪掉的界桩、发黄的图、城下多出来的几座新坟、粮行门口的长队。
6. **白话**。不写「之乎者也」「臣」「府库」「廷议」，不堆四字成语；句子里要有具体的名词。
   半文不白是最伤沉浸感的写法——要么是好的白话，要么别写。

### 3.3 改写示例（开渠）

```text
旧：一名自称沈渠的水工跪在殿前，摊开一卷引水渠图。他说凿渠可灌城外的泽卤之地；
　　你的廷议里，有人低声提醒：东边的邻国正盼着我们把民力耗在土方上。

新：殿里烧着炭，门口还是漏风。沈渠跪在石板上，膝盖底下垫着那卷渠图，图角被手汗
　　浸得发软。他不是本地人，说话带着东边的口音，报名字的时候顿了一下，像在想要不要
　　用真名。他说这条渠能把河水引进城外的盐碱地，三年以后，那片白花花的地能长麦子。
　　没有人接话。管粮的官吏低头翻册子，算征发民夫要吃多少粮；杜衡站在柱子旁边，
　　一直没有看你。最后是他先开口：东边的邻国，正等着我们把青壮年都耗在土方上。

　　[A] 把渠交给他，征发民夫　[B] 先关起来，把图验清楚　[C] 停工，让人回去种地

结果（动工了）：民夫在河边扎下营寨。国库拨出的口粮先到，名册后到，念名字的人念错了
　　好几个，没人纠正。有人说是仁政，也有人说，这是把种地的人赶去挖土。
```

### 3.4 三条硬规矩

1. **不写读数，写人话**：价格、库存、人口、百分比、日期都不进正文；「三百人」「三成」「两亩」可以写。
   —— 这是叙事，不是报表。
2. **不借用真实历史**。这个世界是架空的：人物、国名、地名、职官、引文全部自造（水工 沈渠 / 老臣 杜衡 /
   城门吏 王顺）。真实制度只能当机制骨架，不能连名字一起搬。写完自问：玩家会不会认出「这是某段真史」？
   会，就重写。
3. **结果必须落到人**：效果行是账（谁得钱、谁失地），结果段落是人（谁活了、谁走了、谁在背后骂）。
   只有账没有人，玩家感觉不到「我的决定改变了谁的一生」。

### 3.5 让回声听起来像人

- 赈济之后必有「善后」：活下来的人要名分（上户籍 / 遣返），玩家的「仁政」要付第二次账。
- 驱散之后必有「余波」：抬 `unrest` 权重，让下一场动荡替那群人说话。
- 工程之后必有「受益者与失意者」：民夫拿到工钱、粮价涨了一成、老户叫新户「粥棚户」。

---

## 4. 四种可复用的结构

1. **单事件**：3 个选项、2 个确定性 + 1 个博弈。适合一次性风物。
2. **两幕因果**：第一幕给「授权/拒绝」，第二幕用两个不同 event_id 承接。适合工程、制度、战争。
3. **状态回声**：脉冲事件 + `required_story_flags`，让某个标记在几十天后自然回响，而不是定时弹。适合「余波」。
4. **人群善后**：救助/驱散 → 定时排「善后」幕，逼玩家为「人」再做一次决定（城门外的人 → 粥棚撤了）。

节奏建议：一条完整链 **2~4 幕**、总时长 **不超过 3 游戏年**、最后一幕给一次全国性/长期效果。

---

## 5. 世界内典故：怎么造一个「像史」的过去

**这个世界是架空的，但文本允许专名。** 分三层用：世界内专名（人名、地名、器物、书名，必用，每条正文至少两个）、制度专名（行会、教团、钱监、驿馆、漕运，常用，按时代与地块挑）、真实史事（只作人物口中的类比，每条最多一处，不复述过程与结局）。判据不是「玩家能不能认出类型」，而是「能不能指出这是某一件史事的逐段复述」——能，就重写。完整规则、史相台账与网络结构见 `narrative-event-web.md`。

### 5.1 三步造典法

1. **先定机制，不先定人物**：平粜、屯田、官营、漕运、债券、盐引……选一个能在现有数值里跑通的机制。
2. **再定「谁推、谁挡、谁付账」**：一个具名推动者（本世界的人名）、一个具名反对者、一群付账的人。
   三方都有名字，事件就立起来了。
3. **最后让一句话或一个动作留在画面里**：不要格言，不要口号；一句在场景里说得出口的话，或者一个没做完的动作。

### 5.2 造词边界

| 项 | 可以 | 不要 |
| --- | --- | --- |
| 人物 | 自造人名：水工 沈渠 / 老臣 韩宿 / 行首 沈砚舟 / 寡妇 岑氏；真实历史人物只在人物口中的类比里出现，且不复述其事迹 | 让真实人物当事件主角、替他说史书上的话 |
| 国名 | `{country_name}`、方位（东边的邻国、下游诸邦） | 用真实国名 / 朝代名替换玩家国家 |
| 地名 | `{settlement_name}`、自造地名：雁回堡、沙尾港、白榆林 | 把真实山川关隘当作本地地名 |
| 职官 | 功能名 + 有历史质感的制度词：度支房、钱监、行会、驿馆、漕运 | 整套照搬真实官制，让玩家对号入座 |
| 引文 | 自己写；真实典籍原文只在类比里出现一句 | 整段引用史料 |

真实制度只能当**机制原型**：保留「买进卖出 / 工期 / 两条互斥路线」的骨架，把名字、地点、人物全部换掉。

### 5.3 机制原型清单（只给骨架，名字自己造）

| 原型 | 触发 | 效果杠杆 | 为什么值得写 |
| --- | --- | --- | --- |
| 官仓平粜 | 粮价 ≥1.3 × 人口 × 河流 | `COUNTRY_GOOD_TO_MARKET` + `wheat_grain.output_factor` + 标记 | 唯一能直接吃「价格」系统的机制 |
| 外来早熟作物 | 沿海 × 温暖 × era 3–6 | `DISCOVER_RESEARCH_SIGNAL`(`bio.rice`) + `rice_grain.output_factor` | 科研线索效果目前全库零使用 |
| 圩田争地 | 三角洲/海岸 × 河流 | `rice_grain +` 与 `freshwater_fish.regen_factor.cut` 同时给 | 正负效果成对，才有取舍 |
| 山地井渠 | 干旱 × 内陆 × 高地 | `agriculture +` + `fertile_soil.regen_factor` | 与开渠同族但地块不同 |
| 官营与放任 | era 3–4 × 国库/满意度 | 两条互斥路线：`COHORT_CASH_TO_TREASURY`+制造 vs `TREASURY_CASH_TO_COHORT`+贸易 | 财政路线之争，天然双选项 |
| 长距离粮运 | 河流 × 沿海 × era 3–5 | `country.trade.capacity_factor` + 失败分支的 `unrest` 偏置 | 工程与民力的两面 |
| 信用票据 | 贸易建筑 × 纸张/印刷科技 | 现金转移 + 贸易容量 | 把「信用」写成即时现金流 |
| 黑色燃料 | `HAS_NATURAL_RESOURCE oil` × era 7+ | `energy` 部门产出 + 科研线索 | 资源门槛目前全库零使用 |
| 社仓 | 已有官仓标记 × 灾年 | `MARKET_ADD_STOCK` + 消费修正 | 演示「状态回声」结构 |
| 商品投机 | 贸易建筑 × 奢侈品价格比 | `COHORT_CASH_TO_TREASURY` 与反向转移 | 纯现金流博弈，最容易调平衡 |

### 5.4 人群题材（直接从系统里长出来）

| 题材 | 触发 | 效果 | 适合的「人」 |
| --- | --- | --- | --- |
| 城门外的人 | `SUBSISTENCE_SHORTFALL_GTE 0.15` | 国库存粮投放本地市场 + 以工代赈的现金工钱 + 善后排程 | 城门吏、逃荒佃户 |
| 盐户抗税 | `PROFESSION_SHARE_GTE`（盐工）+ 税率/国库 | 现金转移 + 消费修正 + `unrest` 偏置 | 盐户、巡盐吏 |
| 匠户逃籍 | `UNEMPLOYMENT_GTE` + 工业建筑 | 制造产出 ±、人口出生 | 老匠、学徒 |
| 码头争埠 | `PROFESSION_SHARE_GTE`（商人/码头工）+ 贸易建筑 | 贸易容量 ±、`COHORT_CASH_TO_TREASURY` | 行会、船户 |
| 渠田争水 | 河流 + `PROFESSION_SHARE_GTE`（农户）+ 粮价 | 农业 ±、`unrest` 偏置 | 上户、下户 |

---

## 6. 示范逐段解读

### 6.1 开渠四幕（水利包）

- **第 1 幕 · 开渠**（脉冲）：河流 + 平原/泛滥平原 + 湿度 ≤0.55 + 人口 ≥8 + `tech.irrigation`。
  权重吃湿度、人口、麦价。三选项：授权（2.5% 国库 + 周边 2 环农业 +3% + 全国建设成本 −5%/240 日 + 30 日后通水）/
  先囚后验（55% 他画了一夜图，1.5% 国库 + 周边 1 环知识 +4%）/ 停工（收 1.5% + 周边 2 环农业 −3% + 档案标记）。
  正文从殿里的炭火、漏风的门、沈渠膝盖下被手汗浸软的图写起。
- **第 2 幕 · 通水**：引洪淤田（周边 2 环农业 +12%、主食开销 −8%、全国农业 +4%、730 日后渠田丰收）/
  折钱（向本地人数最多的职业征其现金 3%，周边 1 环制造 +4%，不搬物资）/
  漫灌（60% 周边 2 环农业 +18% + 主食 −10%；40% 周边 2 环农业 −10% + 主食 +8% + 国库 2%）。
  正文落在民夫蹲在渠边等工钱的姿态上。
- **第 3 幕 · 半条渠**：藏图（付 1.5% 续凿 + 周边 1 环知识 +5% + 清标记 + 120 日后重启）/ 罢议（收 1.5% + 周边 2 环农业 +3%）。
- **第 4 幕 · 渠田丰收**：全国建筑产出 +5%（730 日）+ 全国军队补给消耗 −10%（730 日）+ 周边 2 环农业 +4% +
  主食开销 +5% + 向本地人数最多的职业征收其现金的 2%；
  补贴路线：国库 3% + 周边 2 环农业 +6% + 主食 −10% + 出生率 +5%。

### 6.2 城门外的人 → 粥棚撤了（人群包）

- **城门外的人**（脉冲）：`SUBSISTENCE_SHORTFALL_GTE 0.15` + 人口 ≥8；权重吃失业 ≥15%、小麦价格比 ≥1.25、最不满群体 ≤0.40。
  三选项：开仓设粥（本地市场增补小麦 300 单位，官府调拨；需该格有商人；45 日后善后）/
  雇本地人修堤（国库现金 2.5% 给本地人数最多的职业作工钱 + 本地农业 +4%/360 日 + 60 日后善后）/
  关门驱散（65% 散去但动荡概率 +30%；35% 夜半鼓噪，农业 −8% + 动荡 +50%）。
- **粥棚撤了**（定时）：上户籍分田（本地农业 +5%/540 日 + 本地老户的怨气：动荡 +15%/180 日）/
  遣返原籍（清标记，无后续）。
- 这一幕的意义：**赈济不是句号**。玩家为自己的「仁政」付第二次账，才像在治理一群人，而不是点了一个按钮。

### 6.3 契约测试在测什么

`tests/game/narrative_event_waterworks_chain_test.gd`（333 项）：
形状（4 事件入库、正文 3–8 句且 ≥100 字、无引语块、选项 4–16 字、概率和 = 65536、确定性选项 ≥75%）、
写法（每条效果都有 `custom_label`、修饰键都在编译目录里、排程目标存在）、
触发（缺河/山地块/过湿/无科技/era 9/人口不足逐一为 0）、路由（授权→通水→渠田；停工→半条渠→清标记→重启）、
数值（标签百分比 vs 原生实测乘数）。

`tests/game/narrative_effect_radius_test.gd`（47 项）：
`radius=0` 单格向后兼容、1 环均等、2 环 100%/60%/30%、每格独立 source id、单格失败不中断、
`to_dict/from_dict` 往返与 clamp、`describe()` 后缀、AI 字段、采样器只取己方陆地并去重排序。

`tests/game/narrative_event_people_test.gd`（38 项）：
引语字段存读（schema 层，内容层禁用）、人群采样（人数最多者的职业 / 入不敷出 / 失业 / 职业占比）、
四个新条件、现金转移的收款人与职业标签、饥民触发（吃饱的格子不出、饿的格子出、越惨权重越高）、
善后链、弹窗正文与结果段落。

### 6.4 主题事件网（8 包 34 条）

`tests/game/narrative_event_web_test.gd`（15000+ 项，随事件数自动增长）：
注册与 pack 元数据、文字契约（句数/字数/无读数/引语配额）、专名密度、效果键与标签数值、
**取舍契约**（每个选项至少一种代价、同一事件的选项代价不重复）、引用完整性（排程/偏置/事件门/标记门都能解析到生产者）、
图结构（非入口有硬入边、多入边节点数、跨包边数、时代窗口相交、BFS 可达）、
触发分层（每条 ≥2 条权重规则、≥2 个条件维度、发达格权重高于荒凉格）、
行为（边将坐大阻断借饷、市场增补必须有商人、定时链按日触发）、
数值对账（标签百分比 vs `DCWorldExt` 实测乘数）。

网络结构、史相台账与扩展 SOP 见 `docs/design/narrative-event-web.md`。

跑法：

```powershell
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes `
  --script tests/game/narrative_event_people_test.gd --quit
```

---

## 7. 已知偏差与后续

1. **既有 10 条事件已按审计修正（2026-11-11）**：
   - `family.city.agriculture/manufacturing/knowledge/extractive_output_boost` → `economy.city.building.<sector>_output_factor` + `_pct(卡面%)`；
   - `family.city.birth_cut` → `economy.city.birth_factor.cut` + `_pct(20)`；
   - `family.city.trade_output_boost`（目标 stat 全引擎 0 读取点，真空转）→ `family.country.trade_capacity`（全国贸易容量，被贸易规划读取）；
   - `ideology.country.output.*_factor.gain` 的 magnitude 从 1.15 降到 `_pct(15)=9830`，卡面 +15% 才与实测一致；
   - `family.city.production_boost` 上限只有 +4%，卡面统一改成实测的 +2%；
   - `ADD_EVENT_WEIGHT_BIAS` 统一成「只给乘数」，标签改「权重 ×1.3 / ×1.5」，不再写「概率 +30%」；
   - 守恒转账标签统一写「本地人数最多的{primary_profession}」，不再写「地方资金 / 本地居民」。
2. **`NarrativeEffectSpec.describe()` 的百分比是第三套约定**（`(magnitude−1)×100`）。没有 `custom_label` 时，生成族会显示成 −80%、手写族会显示成 +15%。新内容请一律写 `custom_label`；AI 事件若漏写，卡面数字仍会错——这是下一项要修的地方。
3. **13 个只写不读的 story flag**（`flag_winter_hardship` / `flag_unrest_simmering` / `flag_cavern_mastered` /
   `flag_canal_authorized` / `flag_canal_abandoned` / `flag_gruel_kitchen` / `flag_relief_works` / `flag_hungry_refused` 等）：
   它们是持久化档案与未来扩展点，但当前没有 `required_story_flags` / `blocked_story_flags` / `HAS_STORY_FLAG` 读取，
   所以**没有机制作用**。要机制化就接到脉冲事件的门槛上；不接就当纯记录，不要写进卡面期望。
4. **`MARKET_ADD_STOCK` 的硬条件**：该格必须有商人（`cannot_add_stock_without_local_merchant`），
   且数量按原始单位算（每人每日主食约 440 = 0.44 单位）；写几十单位等于没写，按人口口粮估。
5. **AI 事件仍是短句简报**：正文 ≤2 句，不写场景，也不写引语块；`outcome_narrative` 会被 validator 截断但 prompt 不再要求生成。
   若要让 AI 也写小说式正文，需要先解决「池化复用 + 具体人物会过期」的矛盾。
6. **弹窗在矮窗口下依赖滚动**：逻辑高度 < 700 时，长正文会把选项推到滚动区；结算页会隐藏正文与引语区，把版面留给结果。
   这是刻意兜底，不是 bug。
7. 探针排错经验：`evaluate_modifier_stat` 的 `group_handle` 是**格子索引**，传超出 `configure(cell_count)` 的值会静默读到 1.0。
   曾因此误判「need 消费修正无效」——实际有效（见 2.2）。写探针时先确认索引范围。
   事件网的数值对账把 `cell_count` 提到 512、每个效果独占一格，就是为了避开这条静默失败。
8. **标记与修正最长 1825 日**：`NarrativeEffectSpec.clamp_safe()` 把 `duration_days` 压到 `[1, 1825]`，
   所以 `SET_STORY_FLAG` / `ADD_EVENT_WEIGHT_BIAS` / `CITY_MODIFIER` 都活不过五年。
   跨时代的因果必须用 `required_events_completed`（引擎对所有**已结算**事件永久记账，与 `one_shot` 无关）；
   标记只做短程门与权重支点。
9. **定时通道不复核条件与 `one_shot`**：同一节点被两条父边排程会重复触发。收束幕请写成「可以再来一次」的语气，
   或只保留一条排程父边。
10. **效果与文本必须同向**（2026-11-12 全量审读）：曾出现「发工钱」实际向人群征 3%、「账面亏空」实际 cash_in、
   「粮价涨」实际农业 +3% 这类反向错位。写结果前先看效果行，正文只写效果做得到的事；详见 `narrative-text-review.md`。
   契约测试 `_test_price_claims` 已强制：结果文本出现“价涨/价落/变贵”时，必须带 `MARKET_*` 或 `good.*`/`staple_food` 修正。
11. **核心事件也要时代门**：`narrative_event_catalog.gd` 的 10 条基础事件曾完全没有 `min_era_index`，
   石器时代会弹「居民代表联名请愿」。链式排程节点不要单独设时代门——时代门只设链首，否则低时代的手动推进会卡住。
12. **重复套路是债**：蹲、沉默句、站了很久、册子多一行、钥匙、界石、收进怀里、第二天早上，各自跨 10+ 包出现。
   新写一条时先查本包用过没有；契约测试 `_test_repetition_budget` 已按**单条事件**设上限：
   蹲 ≤2，钥匙 / 界石 / 沉默句 / 站了很久 / 册子多一行 / 收进怀袖 / 第二天早上 各 ≤1。
   全量清理与跨包配额见 `narrative-text-review.md` §3。
