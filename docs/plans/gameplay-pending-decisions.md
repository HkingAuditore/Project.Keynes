# 玩法待定项

这些测试失败都涉及玩法、内容或数值规则，需要你拍板，所以代码和测试都没改。它们不计入 `execution-queue.md` 第 9 项的修复范围。

每条包括以下几部分：
- 对应的测试；
- 2026-11-14 在 PR #6 分支（macOS arm64 调试版）上逐个重跑的结果；
- 涉及的代码；
- 要定的问题和可选做法。

定下来以后，按结论改代码或改测试，再把这条从本文删掉。

## 1. 外国 AI 不研究科技

- **测试**：`tests/runtime/runtime_country_ai_test.gd`，失败 1 条：`foreign research queue is planned, player queue is empty`。
- **现状**：
  - AI 的战略、研究、税收三个模块都在运行，发出的指令没有被拒；
  - 60 天后外国的研究队列是空的；
  - 该国现金充足，但研究日预算为 0，科技点库存为 0。
- **代码**：`gdext/src/country_ai_core.cpp` 的 `think_research`。
  - 研究日预算按"可支配现金 × 议程份额 ÷ 周期"计算。
  - 队列为空（`queued_total == 0`）时预算直接取 0（第 439 行）。
  - 所以排不进科技，就不会有预算。
- **要定的问题**：AI 是否应该自己设研究预算并排队。
- **可选做法**：
  - A. AI 负责研究：排队时放宽候选条件，或在队列为空时也保留最低预算。外国会开始消耗现金研究，影响外国发展速度。
  - B. 保持现状：外国不主动研究，测试改为不要求外国队列非空。

## 2. 开局人口增长太慢

- **测试**：`tests/world/map_activity_runtime_integration_test.gd`，失败 1 条：`ACTIVE native population commit starts visible growth effect`。
- **现状**：
  - 测试以 50 倍速跑 20 秒，走到约第 100 天；
  - 建筑完工的表现正常；
  - 初始聚落的人口增长表现一次都没有触发。
- **要定的问题**：开局人口应该多快开始增长。
- **可选做法**：
  - A. 调快开局人口增长，让前 100 天内能看到增长。这会改人口平衡。
  - B. 保持现状，测试改为等更久，或改用别的增长信号。

## 3. 水路连通后没有贸易

- **测试**：`tests/world/water_transport_runtime_test.gd`，失败 1 条：`shallow-sea tech lets the same strait dispatch a domestic order`。
- **现状**：
  - 有浅海科技后，水路在路由上是通的：6 个港口节点、6 条连线，没有路线被拒；
  - 但两岸的供给信号和需求信号都是 0，所以没有生成国内订单。
- **要定的问题**：两岸市场是否应该自然产生贸易信号。
- **可选做法**：
  - A. 市场应该自然产生供需信号，让水路贸易在夹具里自动发生。这要改经济的信号生成。
  - B. 信号只来自真实缺口，测试改为在夹具里人为制造一侧的缺口。

## 4. 军事装备解锁闭包不一致

- **测试**：`tests/military/military_unit_unlock_consistency_test.gd`。
- **现状**：17 个装备槽不一致，另有 2 条解锁闭包错误。
  - **兵种解锁时装备还锁着**，例如：
    - `bronze_spearmen` 的 `hide_armor` 需要 `tech.hide_tanning`；
    - `shield_bearers` 的 `bronze_weapons`；
    - `early_tanks`；
    - `powder_shot`。
  - **装备没有已解锁的生产者**，例如：
    - `bows`、`flintlocks`、`rifles`、`iron_armor`；
    - `steel_artillery`、`modern_tanks`、`missile_launchers`。
  - **`hide_tanning` 的解锁闭包会解锁 `bows`**，跨过了 `tech.composite_tools`、`tech.military.standing_army` 等前置。
  - 第 6 节产业链测试里另有 26 种军事装备"没有消费者"，同属军事目录与经济目录没对齐的问题。
- **要定的问题**：兵种解锁时，装备是否必须已经能生产。
- **可选做法**：
  - A. 必须能生产：补齐军事目录、生产建筑和科技前置，让每个兵种解锁时装备都能造。这是内容工作量。
  - B. 允许"兵种先解锁、装备稍后补齐"：测试改为只检查装备最终可达。

## 5. 时代奖励：提醒还是直接弹出

- **测试**：`tests/technology/era_reward_notification_regression_test.gd`，失败 7 条，比 11-13 记录的 3 条多。失败的检查包括：
  - `notification-only milestone remains a deferred reward`；
  - `waiting reward preserves running speed and commands`；
  - `later commits do not reopen a deferred reward`。
- **现状**：
  - 测试（2026-10-30）要求时代奖励只做提醒，由玩家点徽章再打开，等待期间时钟照常走。
  - 上游代码（2026-11-03）改成晋升后直接弹出三选一，并暂停时钟。位置在 `scripts/game/player_controller/progression.gd` 约第 74–79 行，注释写的是"三选一直接推到玩家面前"。
- **要定的问题**：以哪个为准。
- **可选做法**：
  - A. 直接弹出（上游现行做法）：按新行为重写这个测试。
  - B. 只提醒：撤回上游的自动弹出。

## 6. 科技规则与内容

### 6a. 王国时代的研究资格与研究路线

- **测试**：`tests/technology/technology_eligibility_v2_test.gd`，失败 14 条。
- **已记录的待定问题**：王国时代节点能否在没有农业里程碑时研究和入队。相关失败：
  - `kingdom node can enter the queue without the agrarian milestone`；
  - `revealed kingdom node is researchable without the agrarian milestone`；
  - `kingdom milestone opens after the previous era and candidate threshold`；
  - 以及随之失败的 `eligible node can enter the queue`、`eligible enqueue command commits`（2 条）和 `one complete research route produces eligible state`。
- **新看到、来源未查的失败**：以下几条研究路线打不开：
  - 燧石研究（`the unified institution route opens flint research`）；
  - 季节历法（`... opens seasonal calendar after its core history`）；
  - 淡水/海洋捕鱼（`freshwater/marine evidence opens ... fishing after knowledge and net fiber`）；
  - 渔船（`completed coastal/freshwater fishing alone opens fishing boats`）；
  - 畜牧（`a domesticable animal signal reveals husbandry`）。

  之前的日志在这个测试里直接崩溃，没法比较，所以还不能断定是玩法问题。可能是上游科技 v5 改了内容，测试没跟上。要先查清，再决定归哪类。
- **可选做法**（只针对王国时代资格）：
  - A. 王国节点必须等农业里程碑：测试改为期待被拒。
  - B. 不需要等：放开资格检查。

### 6b. `tech.composite_tools` 是否只做支撑

- **测试**：`tests/technology/technology_topology_audit_test.gd`。
- **现状**：
  - 第 87 行断言失败：`tech.composite_tools support_only has direct bindings`，即这个科技被标为"只做支撑"，却直接绑定了内容；
  - 断言失败后脚本没有退出，所以跑满 300 秒超时。超时只是断言失败的后果，不是另一个问题。
- **可选做法**：
  - A. 去掉它的直接绑定，挪到别的科技上；
  - B. 去掉 support_only 标记。

### 6c. 产业链的时代、产率与消费

- **测试**：`tests/technology/technology_industry_chain_balance_test.gd`，共 39 条：
  - **26 条"商品没有消费者"**：全部是军事装备，从 `stone_spears`、`bows` 到 `smart_rifles`、`combat_drones`。经济目录里没有建筑消耗它们，见第 4 节。
  - **8 条"建筑时代与语义不符"**，例如：
    - `rainfed_maize_field`、`highland_tuber_plot` 在王国时代，测试认为应在农业时代；
    - `pastoral_camp` 在农业时代，测试认为应在石器时代。
  - **4 条"升级后产率反而下降"**（后一级 ÷ 前一级）：
    - `bronze_armory → armory` 0.97；
    - `automatic_arms_works → smart_arms_plant` 0.81；
    - `howitzer_works → missile_systems_plant` 0.52；
    - `munitions_plant → guided_munitions_plant` 0.17。
  - **1 条"生产与消费隔得太远"**：`natural_rubber` 在大航海时代就能生产，蒸汽时代才有消费，隔了 2 个时代。
- **要定的问题**：这些是要补的内容，还是测试的标准该放宽。
- **可选做法**：
  - A. 按测试改内容：补消费建筑、挪建筑时代、调升级产率。
  - B. 逐类确认是有意设计的，就改测试标准。例如军事装备由军队消费，不算经济消费者。

### 已不在待定列表里

- `technology_content_binding_audit_test`：这次重跑已经通过。
- `technology_refresh_latency_test`：原来要定的显示延迟问题（600ms 预算）这次各项都通过了。只剩 1 条 `research replica moved while the panel was closed`：面板关闭的 6 天里研究进度没变。看起来是测试夹具的问题，可能 3 项排队科技在前面的测量阶段已经研究完，但还没证实。它不是玩法问题，已移到第 9 项。

## 7. 现代经济的目标内容

- **测试**：
  - `tests/ui/modern_economy_catalog_test.gd`，失败 129 条；
  - `tests/ui/modern_economy_runtime_test.gd`，失败 38 条。
- **现状**：测试描述的是一套还没落地的目录规格。目录测试失败的例子：
  - 书写材料并进抄写坊配方；
  - 电线可用铜或铝做导体，且不消耗绝缘材料；
  - 升级层级唯一且对齐（`household_loom`）；
  - 两个所有者的转换要保留各自产能（`marine_fish_collector`、`freshwater_fishing_camp`）；
  - 工具槽使用工具类别（`chariot_wright`）；
  - 自给农业的产出要按标定逐级提高（`subsistence_farm`、`improved_smallholding`、`three_field_smallholding`）；
  - 自给采集开局即可用；
  - 石器时代狩猎能养活猎人，并产出兽皮和毛皮；
  - 起步知识路线使用本地建造（`early_knowledge_institution`）。

  运行时测试失败的例子：
  - 家庭响应周期没有提交（4 条）；
  - 科技授予没有排队（4 条）；
  - 零库存时小麦、稻米、玉米不产生需求；
  - 电力预处理没能在同一周期供电；
  - 石器时代建筑没有先建后替换；
  - 升级周期的各账本不守恒。
- **要定的问题**：现代经济以这套测试规格为目标，还是以现有目录为准。
- **可选做法**：
  - A. 按测试规格补内容，工作量大。
  - B. 按现有目录重写测试。

  不管选哪个，账本不守恒那条都应先单独查一下：它可能是真 bug，不是内容差异。

## 8. 经济内容规则

这些问题 11-13 就已记录，现在仍然失败。

| 测试 | 失败 | 要定的问题 |
|---|---|---|
| `colonization_starter_regression_test` | 1 条：`starter kit departs with tools still locked` | 工具还锁着时，初始殖民包是立即出发，还是保持准备中 |
| `crop_technology_parity_test` | 6 条：土豆的 `highland_tuber_plot` 气候；药草的 5 个建筑和方法的土地资源 | 土豆适合什么气候，药草用哪张土地资源表 |
| `economy_goods_lifecycle_audit_test` | 172 种商品没有可达的生产者，469 个建筑不可达。例如石器时代的 `wheat_grain`、农业时代的 `wool`、王国时代的 `wrought_iron` | 这是内容缺口，还是审计标准过严 |
| `economy_map_generation_test` | 4 条：开局只有一包过渡库存且全员失业；玩家检视面板隐藏科技锁定的商品和资源；有人口的格子在石器时代中期就有资源专业化；接口提供配方候选和多角色产出信息 | 开局经济该是什么样子 |
| `treasury_construction_runtime_test` | 2 条：AND/OR 规划要选一个共用替代品并合并两组；结构效率 50% 时跨组总共要正好扣 60 | 国库建造的材料替代与结构效率规则 |

以下测试这次已经通过，相应问题不再待定：
- 贸易能否经过中立地和第三国：`economy_trade_runtime_test`、`trade_visual_runtime_test`；
- 家族殖民包的建筑组合、N=3 方案和奖励时点：`family_colonization_runtime_test`。

## 9. 科研预留与补贴谁优先

- **测试**：`tests/economy/economy_rolling_runtime_test.gd`，失败 3 条：
  - `next matching rolling batch pays treasury-capped subsidy`；
  - `zero-market-income cohorts receive the funded living-cost floor immediately`；
  - `empty target profession receives prospective subsidy budget`。
- **现状**：
  - 财政预留前，先扣掉一个周期的科研预算：`gdext/src/economy_runtime_fiscal.cpp` 第 695–709 行，`research_floor` = 科研日预算 × 周期天数，可预留额 = 可支配现金 − `research_floor`。
  - 开局默认科研日预算是 1000 万，自动采购默认开启（`scripts/country/map_country_initializer.gd` 第 582–584 行）。
  - 所以国库低于这个数时，能用来发补贴的钱恒为 0。
- **可选做法**：
  - A. 补贴优先：先预留补贴，剩下的再给科研。
  - B. 科研优先（现状）：测试夹具里调低科研预算或关掉自动采购。
  - C. 默认科研预算改为按国库比例设定，而不是固定 1000 万。

## 10. 建筑资源链测试跟不上内容改动

- **测试**：`tests/building/building_resource_chain_test.gd`，失败 4 条：
  - `mining efficiency improves across historical building tiers`：金矿、银矿的产出和资源消耗在 `a746c3d50` 里调过，测试仍按旧效率；
  - `textile mill consumes direct fiber, power, maintenance tools, and no natural resource`：纺织厂在 `f4d833abb` 里加了第 4 个输入 `dyestuff`；
  - 淡水渔场和近岸渔场"只开采本格储量"两条：由第 11 节的储量放大造成。
- **可选做法**：
  - A. 测试跟新内容：前两条改期望值，渔业两条等第 11 节一起处理。
  - B. 回退这两次内容改动。

## 11. 矿产储量被放大 100 倍（疑似 bug，推迟到调资源平衡时修）

- **测试**：`tests/economy/natural_resource_distribution_capacity_test.gd`，失败 23 条：
  - 11 种矿产各有 2 条：`honors target world reserve` 和 `keeps a visible small/micro deposit tier`。这 11 种是 bauxite、gold_ore、lead_ore、limestone、manganese_ore、phosphate_rock、rare_earth、silver_ore、sulfur、tin_ore、zinc_ore；
  - `marine_fish` 1 条：`honors target world reserve`。
- **代码**：`gdext/src/world_ext_resource_deposits.cpp`。
  - 解码参数时已经乘过 `kCellAreaResourceScale`（100，第 42 行定义，第 394–408 行使用）；
  - 第 580–586 行又乘了一次。
  - 结果是目标储量密度、平均储量和微型矿下限都被放大了两次。
- **修法**：去掉第二次乘法。
  - 修完后，所有矿产的初始储量会降到现在的约 1/100；
  - `NATURAL_RESOURCE` 哈希会变；
  - 经济平衡要跟着调。
- **已定**：2026-11-13 你决定先不改，等调资源平衡时一起修。所以这条只等你排期，不需要再做选择。
