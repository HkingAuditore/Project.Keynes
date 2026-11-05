# 军事系统内容设计审查（2026-11-05）

> **2026-11-05 后续修复**：§2.1 描述的补给候选表失效已修，且根因比初判更广——GDScript 写时复制让 **6 类候选表全部为空**（含 ration/fodder/fuel），而非只有 upkeep/ammunition。详见 `docs/military-unit-cost-table-2026-11-05.md` §5 与 `tests/military/military_supply_catalog_test.gd`。本文其余结论仍描述修复前状态。
>
> **2026-11-05 二次修复**：§1.1 / §1.2 / §4.1 / §5 里「部落战士开局恒解锁」的结论已失效。`tribal_warriors.tech` 现为 `tech.composite_tools`，民兵 `supply_*.upkeep` 归零，开局唯一恒解锁兵种是不需要任何物资的民兵。详见 `docs/military-unit-cost-table-2026-11-05.md` §7 与 `tests/military/military_unit_unlock_consistency_test.gd`；§6 A5 的主诉求已落地（但选了更早的节点）。
>
> **2026-11-05 三次修复**：本文与 §7 曾列为「遗留」的 13 个有科技门兵种装备闭包缺口已全量修复，见成本表 §8。`bronze_spearmen.tech` 现为 `tech.hide_tanning`（三件装备全部就绪的最早节点），§1 表 A 的解锁科技列随之过时。
>
> **2026-11-05 四次修复（原生 v3）**：§2.2「训练下单即改兵种」、§2.4「手动训练无科技闸」、§6 A4「装备质量不进实战公式」三条已一并实现，见成本表 §9。训练期兵留在来源兵种，装备按稳定订单 id 逐槽累计、全部到齐才完成训练并按实际到货档位成军；`equip_factor_q16` 同时进入实战与 UI/AI；PKMI 升 v3，旧档需新开局。

> 审查对象：Project.Keynes 军事系统的**内容/数值设计引导**，不是 UI 文案。
> 方法：3 轮、11 个只读子任务（单位目录 / 军需产业链 / 科技树拓扑 / 面板与地块页 / 原生数值运行时 → 交叉复核 → 红队挑错），所有结论带 `文件:行号`。
> 路径约定：`Project/...` 相对 `D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/`；`gdext/...` 与 `docs/...` 相对仓库根 `D:/Godot/ProjectKeynes/Project.Keynes/`。
> 全程未修改任何生产文件；本文是新增审计文档。

---

## 0. 结论摘要

**核心判断：引导被做在了文案层，数值层没有对应物。** 科技树的军事节点在作者元数据里把「由什么实践/地形揭示」写满（36/36 有 `reveal_summary`），但可执行 `reveal_condition` 是 36/36 全空；面板用「兵营会继续征召」「等装备」「待结算」描述状态，却没有一个数字把这些状态连到真实瓶颈。开发者感受到的「一头雾水」不是提示不够，而是**成本通道、战力通道、解锁通道三者之间没有连边**。

四个抱怨的核实结果（含需要修正的部分）：

| 抱怨 | 核实 | 需要修正/精确化的部分 |
|---|---|---|
| 开局的民兵没有任何资源需求 | **基本属实** | 数据层 `equipment: []`、`training_days: 0`、五类补给中四类为 0（`data/military/military_catalog.json:722-737`）。但运行时仍扣军饷与口粮（`gdext/src/military_core.cpp:2384-2394, 2412-2419`；`gdext/src/military_core_logistics.cpp:1749-1761`），二者按人头、与兵种无关。准确说法是「**没有任何兵种专属的边际成本**」。 |
| 开局有需弓箭的氏族兵，但产业链没解锁 | **属实** | 实体名是 `tribal_warriors`「部落战士」，非「氏族兵」（`military_catalog.json:982`）。它是 `era:0 / tech:""`，开局名册可见、可点（`scripts/ui/military_view_model.gd:317-325, 626-656`）；`missile_arms` 唯一货物是 `bows`（`:1142-1149`）。**但**：开局并不存在该兵种的部队或训练订单（`config_share_bp` 全 0，`military_core.cpp:714, 723, 2098`），所以是「可见但不可达」，不是「一笔卡住的订单」。另外 `GoodProfile.technology_tags` 运行时是 **ANY**（`gdext/src/economy_runtime.cpp:5073-5082`），只研究 `tech.composite_tools` 就有生产许可；该科技本身有 3 层硬前置闭包 + 揭示条件 + 18 天工期，不能说成「要多标签全齐」。 |
| 军事面板、地块军事页签让人一头雾水 | **属实，且比预期严重** | 不只是信息缺失：玩家点「+5% 编制份额」的命令**落库无效**（字段名不匹配，见 §4.1），开局把目标兵力拉到 1000 也**一个兵都招不到**（兵额恒 0，见 §4.2）。两个主操作都没有可见结果。 |
| 数值设计引导极差、科技树没发挥作用 | **结构性成立** | 但不是「设计者没想到」：设计案里 `branch.military_affairs` 分支族、`unit_unlock`/`state_building_unlock` 校验器都已规划（`docs/plans/military-system-design.md:1158, 1217`），属于**已规划未落地**。也不是「军事科技没有可观察差异」：36 节点里 25 个有 `content_effects`、27 个有 `modifier_terms`、35 个有 `effect_summary`。失效的是**发现—实践—回路层与跨目录绑定**。 |

---

## 1. 数据拓扑：开局第 0 层 vs 装备第 3 层

### 1.1 开局可见的两个兵种都是「零门槛」

`data/military/military_catalog.json` 是全库唯一的兵种数值来源（24 个单位；`assets/military/*.tres` 全是 AtlasTexture 图标）。其中 `tech: ""` 的只有两个：

- `militia`（`:711-739`）：era 0、无装备、训练 0 天、攻 0.5 / 防 0.6、`supply_idle.upkeep 0.05`、`supply_combat.upkeep 0.15`。
- `tribal_warriors`（`:981-1022`）：era 0、`training_days 20`、攻 1.0 / 防 1.0、装备 `melee_arms 10/百人 Q1` + `missile_arms 6/百人 Q1`（`:993-1005`）。

编译器把空 `tech` 编成 `unlock_bit = -1`（`scripts/military/military_catalog_compiler.gd:379-389, 451`），原生 `unlocked()` 对 `bit<0` 恒 true（`gdext/src/military_core_internal.h:110-112`），UI 的 `unit_unlocked()` 对空 tech 也直接返回 true（`scripts/ui/military_view_model.gd:317-325`）。**二次修复后这条只对民兵成立**：`military_roster_gate_test.gd` 已改为断言民兵恒解锁、部落战士需 `tech.composite_tools` 才解锁。

**兵种解锁并非「独立于科技树」**：原生 digest 的解锁位由 `country->has_technology(slot, tech)` 填充（`gdext/src/world_ext_military.cpp:955-972`），UI gate 同源。准确表述是「解锁关系由军事目录 `units[].tech` **单向引用**科技 id 表达，科技树节点不反向声明自己解锁了哪个兵种」。

### 1.2 弓箭链的时点

| 环节 | 数据 | 证据 |
|---|---|---|
| 单位需 `missile_arms` | 6 件/百人，类别唯一货物 `bows` | `military_catalog.json:1000-1005, 1142-1149` |
| `bows` 生产许可 | `technology_tags` 三个，运行时 ANY，任一命中即可 | `data/goods/bows.tres:12`；`gdext/src/economy_runtime.cpp:5073-5082, 5094-5113` |
| 最早产地 | `bowyer_camp`，`technology_tags = tech.composite_tools`，投 logs 1500 + raw_hide 300/日 → bows 1000/日，工期 18 天 | `data/economy/buildings/bowyer_camp.tres:12-13, 22, 37-38, 45-46` |
| `tech.composite_tools` | stone 时代、cost 3000、`is_starting:false`、硬前置 `tech.stone_knapping`、揭示条件 `resource.stone ∧ resource.flint` | `data/technology/technology_network.json:8018-8053` |
| 前置闭包 | `flint_identification`(3900) → `stone_knapping`(3000) → `composite_tools`(3000)，累计 9900 研究点、3 层 | `technology_network.json:7742-7759, 7841-7858` |
| 开局已完成科技 | 7 个石器生存类（采集/狩猎/贸易/枯枝/金银/刮皮），`STARTING_IDS := []` | `scripts/economy/technology_catalog.gd:26`；`technology_network.json` 7 个 `is_starter_eligible`；`scripts/game/start_location_policy.gd:240-279`；`scripts/geography/map_generator.gd:3467-3487` |
| 开局库存 | 国库只放 `technology_points`；市场只放食物/衣物/建材/知识点，所有 goods `initial_stock = 0` | `map_generator.gd:3509-3513`；`scripts/economy/starter_settlement_bootstrap.gd:139-222`；`scripts/data/good_profile.gd:45` |

**「可交易」不等于「有货源」**：`good_market_available()` 有 `trade_enabled && storage_mode==0` 兜底（`economy_runtime.cpp:5133-5137`），但那是**权限/可达性**；军需采购实际只在本国控制的 3 格市场环里按 `category_of_good` 找有货的行（`gdext/src/military_core_logistics.cpp:1091-1140`）。开局「有钱无货」成立：国库 1e8（`scripts/game/new_game_config.gd:89`）、采购预算与自动采购都在（`military_core.h:373, 385`），但没有任何 bows 库存或产能。

**时代对齐不是问题，时代内深度才是**：`technology_network.json:315-316` 的契约「首个有效需求最晚不超过首产出一个时代」按字面**未违反**（单位 era0、bows 首产出 era0）。审计实现用 `maxi(first_supply, raw_sink)` 把「需求领先产出」钳成 0 差（`tests/technology/technology_industry_chain_balance_test.gd:103-108`），只防滞后、不防领先；且该测试只加载 `EconomyCatalogScript.compile_native_catalog()`（`:45`），`producer_era`/`sink_era` 只由建筑输入/输出/建材构建（`:65-89`）——兵种的 `units[].equipment` 根本不进表。`docs/产业链时代断层分析报告.md:3, 9, 11` 也只遍历「182 个建筑 .tres + 136 个物资 .tres」的**建筑输入物资**，并主动排除「类别替代」语义，而军需装备恰好是类别替代。**这是一次假 PASS**，不是合规。

---

## 2. 运行时数值：精心设计的梯度在结算里几乎不剩

这是比「加提示」严重得多的一层。

### 2.1 单位级 `upkeep` / `ammunition` 的物资需求根本落不了地

- 数据把 `supply.upkeep` 写成字符串 `"primary_equipment_slot"`，`supply.ammunition` / `supply.equipment` 写成 Dictionary（`military_catalog.json:1509-1537`）。
- 编译器 `_compile_supply` 只接受 **Array** 或恰为 `"@ammunition"` 的 String，其它一律 `continue`（`scripts/military/military_catalog_compiler.gd:842-853`）；`validate()` 只检查 ration 非空（`:236-242`）。
- 桥接只是逐行 memcpy 空数组（`gdext/src/world_ext_military.cpp:521-549`）；采购与消费见空表即跳过（`military_core_logistics.cpp:1064`，`:1787-1809`）。

**后果不只是「扣不到」**：单位级 upkeep 数值仍编译进 `idle_per_100_day` 并计入 `use.need`（`compiler.gd:489-498`；`military_core_logistics.cpp:1762-1774`），空候选类使 `satisfied` 恒 0，于是 `supply_ratio_q16` 被系统性拉低（`:1849-1857`），再经 `cohesion_q16` 惩罚战力（`gdext/src/military_core_war.cpp:138`），特定组合下还能越过 `met_total*2 >= need_total` 的 50% 阈值触发 `condition_q16` 每日 0.5% 衰减（`:1881-1887`）。

也就是说：**兵种维护成本没有变成「花钱」，而是变成了「对所有兵种一视同仁的补给率/装备状况折损」**。`condition_q16` 被 `sum_lot_value` 读取（`military_core_war.cpp:156`），实战系数区间 0.75–1.0（最大 −25%），地板 50%、恢复 1%/天。这是唯一一条「装备状况 → 实战」的间接链路，影响源是补给维持率而非装备质量或到货。

### 2.2 装备质量与到货不产生战力回报

`sum_lot_value` 只读 `count / attack_q16 / defense_q16 / condition_q16`（`military_core_war.cpp:147-161`）；`equip_factor_q16` 全库仅在 `refresh_army_cache` 被调用一次（`military_core.cpp:345-359, 1343`），产出 `cached_attack_q16` 供 UI/AI/交战排序使用，**不进伤害公式**：`world_ext_military.cpp:2782, 2821`；`military_core_war.cpp:1445-1446`；`military_core_logistics.cpp:1422`。

训练下单瞬间 `transfer_garrison` 已把 lot 改成目标兵种（`military_core.cpp:2171, 3195`；`:2023-2045`），`equipment_ready` 只 gate `days_done`（`:2057`）。**装备未到货的部队按目标兵种满攻防参战**。

按每 100 人折算（价格取各槽 `min_quality` 对应 good 的 `default_price`）：

| | 民兵 | 部落战士 | 青铜矛兵 |
|---|---|---|---|
| 装备件数/百人 | 0 | 16（石矛 10 + 弓 6） | 22（青铜兵器 12 + 皮甲 6 + 弓 4） |
| 装备金额/百人 | 0 | 210000 subunit（21 money，占开局国库 0.21%） | 468000 subunit（46.8 money） |
| 训练天数 | 0 | 20 | 30 |
| 单位级 upkeep | 0.05/0.15（**与后两者完全相同**） | 0.05/0.15 | 0.05/0.15 |
| 实际扣到 | 0 | 0 | 0 |
| 攻/防 | 0.5/0.6 | 1.0/1.0 | 1.6/2.2 |
| 进入结算的边际成本 | 0 | ≈0（装备是现金流出但不进战力） | ≈0 |

解锁弓链需 9900 RP / 3 层 + 揭示条件 + 18 天工期 + 建材与投入品；`bowyer_camp` 产能 1000/天，100 人只要 6 把 = 0.006 天产能，**产能也不构成稀缺性引导**。唯一与兵种有关的结算数值只剩 `attack / defense / speed / fortification_ignore / training_days` 与 `fodder/fuel` 两类真实候选。

### 2.3 三个「写了但没接线」的数值

1. **民兵时代系数**：`era_militia_attack_factor_q16 = 88474`（1.35，`military_catalog.json:1558`）是 `kTable[11]` 查表（`military_core_internal.h:121-127`），只进 cached/AI（不进实战）；而 `digest.country_era` 生产侧唯一赋值是全 0（`world_ext_military.cpp:870`，`:883-950` 的经济填充段无任何覆盖），`militia_era()` 因此恒 0（`military_core.cpp:1316-1321`）→ **运行时恒 ×1.0**。「民兵随时代白嫖变强、era3 反超部落战士」只在 selftest 手动注入 era 时成立，**不能作为运行时结论**。
2. **军事 stat 部分未消费**：`MSTAT_ATTACK / DEFENSE / MILITIA / BARRACKS_CAPACITY` 在数据声明、key 表、digest 写入都有（`military_core.h:111-122`；`world_ext_military.cpp:632-649, 993-994`），但军事核心无消费点；`TRAINING_TIME / WAGE / LEVY_RATE / MORALE_ADD / FRONTAGE / CASUALTY` 等已接线。同期 `data/modifiers/default_modifier_catalog.tres` 与 `tools/ideology/add_military_cards.gd:192-206` 也在往这些未接线的 key 上写加成。
3. **JSON/C++ 双份常量**：`quality_multiplier_q16`、`condition.*`、`ration.combat_ratio_q16` 等在 JSON 与 C++ 硬编码各存一份，改 JSON 不改行为（如 `military_core.h:58-60` 对 `military_catalog.json:1546-1552`）。

### 2.4 全局成本与兵种无关

`wage = soldier_daily_wage(country) × count`（`military_core.cpp:2384-2394, 2412-2419`）、`ration = ration_need_per_head_q16 × heads`（`military_core_logistics.cpp:1749-1761`）、`levy` 上限按人口比例（`:1863, 1899`）——三者都是国家/人头标量，24 个兵种同价。招募与手动训练全链路无资源检查、无扣款、无科技闸门（`military_core.cpp:1783-1924, 2873-2888, 3162-3199`；`scripts/game/player_controller.gd:1847-1858, 1870-1873`）；`unlock_bit` 只在自动训练（`:2146, 2185`）、AI 编制与兵营（`military_core_ai.cpp:237, 298`）、官营建筑闸（`player_controller.gd:1878-1882`）检查。

**结论：边际成本 ≈ 0、边际战力 > 0，而战力增量来自 `units[].attack/defense`（免费），不来自装备或科技。** 理性玩家没有数值理由去追军工链——这不是提示词能救的。

---

## 3. 科技树：单向绑定 + 发现/实践回路缺失

### 3.1 军事节点的字段分布（416 节点全量解析）

| 字段 | 36 个 `tech.military.*` 实测 |
|---|---|
| `content_effects` | 25/36 非空，44 条（43 building + 1 good，**0 条 unit**） |
| `modifier_terms` | 27/36 非空，35 条，均带 `runtime_consumer` |
| `effect_summary` | 35/36 非空 |
| `reveal_condition` | **36/36 全为 `{}`** |
| `reveal_category` / `reveal_summary` / `reveal_template_reason` / `opportunity_cost` / `topology_review` / `prerequisite_rationales` | **36/36 全非空（文案层）** |
| `node_role` | 36/36 = `handling`（0 个 identification / production_system） |
| `branch_family_id` | 36/36 非空，但寄居 13 个非军事族（如 `branch.labor_management`，`technology_network.json:63948`） |
| `application_target_ids` / 军事 `application_intersections` / 里程碑候选 / `is_milestone` / `is_era_key` | **0** |

这就是「**文案层写满引导、机制层零谓词**」：`technology_network.json:63950-63966` 写着「战团组织由共同体内部的协作实践与联合狩猎场面揭示」，`research_routes` 却全是 `development.*` / 通用 `tech.*` 模板，全库 `breakthrough.military*` / `practice.military*` 零命中。对照项目自定契约（`docs/cpp-dots-runtime/technology-route-differentiation.md:74, 278-279, 401-404`；`technology-tree-runtime.md:178-190, 309-317`），违反的是「发现→实践→改良→新路线」与「科技完成后必须产生可观察差异」的**回路层**，不是数值差异层。

### 3.2 结构性根因（落到所有权边界）

`docs/plans/military-implementation-contract.md:45-47` 明文规定：兵种/装备/官营建筑在 `data/military/military_catalog.json`（`MilitaryCatalogCompiler → configure_military → NativeMilitaryRuntime` 独占），军需物资/军工建筑/科技节点/Modifier 各进自己目录；`military-system-design.md:996` 又规定军需物资「不进入居民消费计划」。于是：

- 科技树的 `content_effects` 没有 `unit` 类型，`expected_bindings` 全为 building；
- 跨目录审计契约写的是「跨目录」（`technology-tree-runtime.md:315`），实现只加载单一 EconomyCatalog（`technology_industry_chain_balance_test.gd:45`）；
- 240 条 `application_intersections` 零军事链，11 个时代的 143 项里程碑候选零军事，24 个分支族无军事族。

设计案 `military-system-design.md:1158`（`branch.military_affairs`）与 `:1217`（校验器需识别 `unit_unlock`/`state_building_unlock`）**正是修复这条边界所需的最小绑定**，均已规划未落地。同类「已规划未实现」还有 20 张军事理念卡（`:1254-1275`）、24 条家族军事内容（`:1298-1313`）、军工链 `app.*` 交汇（`:1050`）。**报告不应把「设计者没想到」当结论。**

### 3.3 补偿机制：有压力，但没有内容顺序引导

| 机制 | 状态 |
|---|---|
| AI 宣战 / 战争压力调预算 / 按解锁自动配编制与兵营 | 生效：`military_core_ai.cpp:200-204, 227-289, 291-327, 572-596`。但 AI 自身以科技树输出为输入，不产生「下一步研究什么」 |
| 兵额容量硬约束 `posts_for_cell` / 采购预算配额 | 生效：`military_core.cpp:1376-1393, 2127-2128`；`military_core_logistics.cpp:892-899`。是资源上限，不是解锁顺序 |
| 时代跃迁条件 | 生效（`scripts/era/era_advancement_service.gd:208-210, 474-481`），但全为人口/建筑/贸易阈值，且未把真实 era 写进军事 digest |
| 军事 Modifier / 理念卡 / 家族 / 事件 | 部分生效、部分未接线（§2.3）；家族军事内容不存在 |
| 名册科技门 | 生效但单向：玩家须先进入军事面板、选中兵种才看到缺哪项科技，科技树侧无回指 |

**结论**：能形成「要不要扩军」的压力，没有一条形成「看到什么→学会什么→生产选择改变下一轮发现」的闭环。

---

## 4. 面板与地块页：数值在界面上没有对应物

### 4.1 两个主操作实际不生效（最具体的死锁）

**(1) 「+5% 编制份额」落库全 0。**
面板发 `{"unit": id, "bp": 500}`（`scripts/ui/components/military_workspace.gd:660-672`）→ `player_controller.gd:2510-2513` 写成 `entry["shares"] = {"tribal_warriors": 500}` → `military_facade.gd:286-318` 的 `submit()` 只把 `units` 规范化成 `int_pairs` → `world_ext_military.cpp:588-617` 的 `parse_military_command` 只认 `int_pairs` / `units` / `ints`（且 `units` 分支要求键为**数字 dense id**，`static_cast<int32_t>(...)`，`:598`）→ `command.ints` 为空 → `military_core.cpp:3129-3137` 的 `MCMD_CONFIG_SET` **先把全部 `config_share_bp` 清零**，再遍历空 ints。

后果：每次点击都把份额清零（包括 AI 通过 `military_core_ai.cpp:282-288` 正确写入的份额），`share_sum` 仍为 0 → `military_core.cpp:2098` 短路 → **不产生任何训练订单**。正确路径 `military_facade.gd:349-356` 的 `set_unit_config()`（写 `int_pairs`）全库无调用者。同文件的 `force.set_target` / `army.create` 用的字段名原生认得，问题只出在 `config.set` 这一条。

**(2) 开局拉目标兵力招不到人。**
`reset_state()` 清空 `_cell_states` 与 `_lots`（`military_core.cpp:570-573`）；`posts_for_cell()` 无 cell_state 返回 0（`:1376-1390`）；开局经济 bootstrap 只放 kind 0/1 建筑（`scripts/economy/economy_test_bootstrap.gd:148-158, 204-209`；`scripts/economy/economy_catalog.gd:61` 的 `state = 3` 不在候选），无预建兵营；最低档 `warrior_lodge` 需 `tech.military.war_bands`（`military_catalog.json:1198`）且有建材与 10 天工期。于是 `open_sum = 0`，`plan = min(deficit, open_sum) = 0`（`military_core.cpp:1812-1841, 1863-1866`），**一条 ENLIST/LEVY intent 都不发**；且招募每 5 天采样一次（`:1784-1785`）。

因此开局军事侧是**零兵**，不是「全是民兵」；「一旦发出 ENLIST，新兵一律落民兵 lot」（`:1887-1889`）才成立。建成兵营后可恢复（AI 路径 `:3622-3630`；玩家路径 `player_controller.gd:2576-2609`）。

### 4.2 界面读数与真实瓶颈对照

| 玩家看到 | 真实瓶颈 | 界面有没有对应物 |
|---|---|---|
| 「0 人」「人均军费待首次结算」「军饷待结算」 | `per_soldier_cost` 只在首次 `update_force_targets` 后写（`military_core.cpp:1454`）；`daily_wage` 依赖经济 digest | 有 0 值/空串，无因果 |
| 「目标 1000 · 缺 X 人」「兵营会在每次经济结算后继续征召」（`military_view_model.gd:417-418, 526`） | `plan = min(deficit, open_sum)`，`open_sum=0` → 恒 0 | **文字与数值相反**；虽有「N 座 · 兵额 X」合计（`:572-573`）与逐格兵额表（`military_workspace.gd:176-182`），但没有把兵额与「为什么招不到」连起来的算式 |
| 名册「弓箭 Q1 每百人 6 件」（hover，`military_unit_roster.gd:428-435`） | `missile_arms→bows→bowyer_camp→tech.composite_tools`（§1.2） | 只有类别中文名，无货物 id / 产地 / 科技 |
| 「等装备」「N 笔训练订单在等装备到货」「待装备 M 件」 | 训练 demand 的 `missile_arms` 在 3 格市场环无 reach（`military_core_logistics.cpp:1099-1140`）；`equipment_ready` 全库仅由训练类 shipment 送达置 1（`:1518-1523`），**无超时/放弃/退款**，订单无限期挂起 | 只有笔数/件数，无货种、无来源、无解决办法 |
| 「预计日军费 = 滑条 × per_soldier_cost」 | `per_soldier_cost = wage + 30日采购/人数 + 建筑维护/人数` 是**历史人均**（`military_core.cpp:1450-1454`），且 `recruitment_funded: false`（`scripts/ui/country_view_model.gd:753-754`） | 既不是「招兵要花的钱」，也不是「会被扣掉的钱」 |
| 地块页「需 战团组织」（`cell_inspector_view_model.gd:2837-2845`） | 那是兵营/城防/军校科技，与弓箭链**无交集** | 把玩家引向另一条链 |
| 地块页 locked 行无建材报价 | `cost` 只在 `primary_action ∈ build/upgrade/rebuild` 时算（`:2400-2406`） | 锁定态看不到任何数值 |
| 总览「补给不足会掉组织度」（`military_view_model.gd:532`） | `organization_q16` 原生已导出（`world_ext_military.cpp:2786-2787, 2824`），UI 的 `army_row/dossier/front_dossier` 全不读 | 玩家被一个读不到、看不见、无法干预的数威胁 |

**不对称是全局性的**：官营建筑侧（地块军事页/营造窗口）把科技锁、逐项建材「名称/数量（国库 X / 市购 Y / 缺 Z）」、现金、工期、维护、卡点短因由、主键禁用全做齐了（`cell_inspector_view_model.gd:2540-2555, 6233-6253`；`military_building_row.gd:303-309`）；兵员侧只有目标滑条与份额 ±5%，且两者当前都不生效。

其它数值自洽性问题：攻/防在兵种卡是单兵系数、在部队行是全军求和，同用 `"%.1f"`（`military_view_model.gd:349-351, 823-824`）；「补给」一名三义（满足率 % / 可支撑天数 / 每百人日消耗）、「军饷」一名四义；两处训练队列字段不一致（面板有 `equipment_ready` 显示「等装备」，地块页只有「剩 N 日」，`cell_inspector_view_model.gd:2286-2296`）；地块驻军条有 `quota` 数据却不显示（`military_garrison_strip.gd:78-85`）；手动 `train` / `army.create` 命令链完整但 UI 层零调用者，军务档案里的「编成」是只读比例带（`military_view_model.gd:923-924, 1032-1034`）。

---

## 5. 玩家开局时序（按代码推演）

| 步 | 玩家动作 | 实际结果 |
|---|---|---|
| T0 | 打开军事面板「兵力」章 | 目标 0 人、「人均军费待首次结算」+ 空值、名册「军饷待结算」、份额条「民兵 100% · 已配 0%」、兵营表「0 座 · 兵额 0」、训练表「没有训练订单」。部落战士卡可见且 `can_raise=true` |
| T1 | 点部落战士 `+5%` | UI 闪「已下达，次日生效」；命令 `entry["shares"]` 无人解析，到期后 `config_share_bp` 被清零 → 份额仍 0% |
| T2 | 目标兵力拉到 1000 | `force.set_target` 生效，`target_value/effective_target=1000`，`per_soldier_cost` 变 ≥1（保底） |
| T3 | 首个结算日 | `apply_due_commands` → `update_force_targets` → `run_recruitment`（5 日采样、`open_sum=0` → `plan=0`）→ `run_training`（`share_sum<=0` 短路）→ 无 procurement、无 shipment |
| T4 | 第二天面板 | 「目标 1000 · 缺 X 人」+「兵营会在每次经济结算后继续征召」；份额条仍 0%、兵营仍 0 座、训练仍空 |
| T5 | 第 5 个采样日 | 同上，`plan=0`，此后每 5 日重复空转 |
| T6 | （若 AI 已写份额且已建兵营）生成训练订单 | `transfer_garrison` 立刻把 lot 改成部落战士；`missile_arms` 无市场货源 → 无 shipment → `equipment_ready` 永 0 → `days_done` 永 0，界面「0/20 日」「等装备」，无超时/退款 |
| T7 | 切到地块军事页签 | 驻军「0 / 0 / 0 / ×1」、三行官营建筑 locked、tooltip「需 战团组织」；该页只能建兵营/城防/军校，**不能建 `bowyer_camp`、不能研究科技、不能采购 bows** |

要摆脱 T6，玩家必须跨四个系统按顺序完成：研究 `flint_identification → stone_knapping → composite_tools`（以及建兵营所需的 `communal_specialization → tech.military.war_bands`）→ 在经济侧建 `spear_knapper` 与 `bowyer_camp` 并筹集 logs/raw_hide/flint 投入品 → 建兵营拿到 `posts` → 让 bows 进入 3 格市场环并送达训练格。**军事面板本身没有任何一个入口能推进这条链**。

---

## 6. 改进方向（全部为数值 / 依赖拓扑杠杆，无提示词）

优先级 P0 = 让「投入→回报」连边；P1 = 重建科技树引导；P2 = 收敛漂移。

| # | 方向 | 具体改动 | 改动层 / 风险 |
|---|---|---|---|
| **A1** P0 | 修 `config.set` 命令链 | `player_controller.gd:2510-2513` 改走 `MilitaryFacade.set_unit_config()` 的形状（dense unit id → `int_pairs`）；给 `config.set` 加一条数值前置（份额写入后 `share_sum>0` 的回执） | GDScript 层；低风险，但需补一条「点 +5% 后快照里份额非 0」的回归测试 |
| **A2** P0 | 让开局军事系统非空 | 二选一：①开局预置 1 座 tier0 兵营 + 少量民兵与石矛库存；②把 `posts_for_cell` 的 0 值改为「至少有一个可招名额」的起步值。**必须同时给 era0 兵种一条开局可得的装备路径**（否则兵营建了也卡在 T6） | 数据 + 原生；涉及开局存档与 bootstrap 回归 |
| **A3** P0 | 给民兵真实边际成本 | `supply.upkeep` 从字符串改成 Array（编译器才填充，`logistics.cpp:1064` 的 empty 短路才解除），并把 24 个 `supply_*.upkeep` 从「0.05/0.15 几乎全员相同」改成随 era / militia 递增（例：民兵 idle `0.05×(1+0.35×era)`，正规军 idle 0.03 恒定）。`supply.ammunition` 同样改成 Array | 纯数据，但会新增一条持续物资流出 → 国库曲线、`per_soldier_cost`、selftest 补给平衡需重标；改 catalog_hash → 存档迁移 |
| **A4** P0 | 装备与实战战力连边 | `sum_lot_value`（`military_core_war.cpp:147-161`）乘 `equip_factor_q16(实际到货质量)`；训练下单不再立即把 lot 改成目标兵种，或改成「缺装时按 0.4~0.6 计战力」；给 `equipment_ready==0` 加超时/放弃/退款 | **必须重编 gdext + 动存档 schema**（`equip_quality_q8` 语义）；战斗基线、AI 强度、selftest 全变 |
| **A5** P0 | 兵种解锁绑到装备链首产出科技 | `tribal_warriors.tech` 由 `""` 改为 `tech.military.war_bands`，并给该科技加 `hard_prerequisite_ids = [tech.stone_knapping, tech.composite_tools]`；`bronze_spearmen` 追加 `tech.hide_tanning` / `tech.composite_tools` 前置 | 纯 JSON，但 `unlock_tech_ids` 变长 → 旧存档解锁位重排 + catalog_hash 失效，必须版本化迁移。**2026-11-05 已按此方向落地，但改挂更早的 `tech.composite_tools`（见成本表 §7）** |
| **B1** P1 | 落地设计案里已有的两条绑定 | 新增 `branch.military_affairs` 族并归位 36 节点；校验器识别 `unit_unlock` / `state_building_unlock`，让科技树 `content_effects` 反向声明兵种解锁 | 纯数据 + 校验器；`military-system-design.md:1158, 1217` 已有规格 |
| **B2** P1 | 补军事发现/实践回路与时代门槛 | 每个时代 `milestone_candidate_ids` 放 1~2 个军事节点（当前 0/143）；给 36 节点补可执行 `reveal_condition`（把已有的 `reveal_summary` 文案编译成谓词）；新增 ≥6 条军工 × 产业链 `application_intersections` | 纯数据，但必须重跑科技树校验器与 `candidate_required` 可达性，否则可能卡死时代推进 |
| **B3** P1 | 修跨目录审计 | 把 `units[].equipment → equipment_categories → goods` 纳入 sink/需求表；去掉 `maxi(first_supply, raw_sink)` 对「需求领先产出」的钳零，新增该类断层的独立检查；同时纳入科技树与军事目录两份 catalog | 测试 + 生成脚本；这是防止同类问题复发的**唯一结构性手段** |
| **B4** P1 | 面板补三类数值列（不是文案） | ①装备「需求 / 库存 / 缺口」逐项；②全国兵额合计 × 目标 × `min(deficit, open_sum)` 的实际可招数；③未解锁兵种的科技名与研究进度（作为状态列）。修 `per_soldier_cost` 的口径（历史人均 → 边际报价或明确标为估算） | View model + 原生快照导出；低风险 |
| **C1** P2 | 收敛双份常量与未接线 stat | `era_militia_attack_factor_q16` / `quality_multiplier_q16` 收敛为单一来源；`MSTAT_ATTACK/DEFENSE/MILITIA/BARRACKS_CAPACITY` 或接线或删除，并把 `digest.country_era` 从经济层真值填充（当前恒 0） | 原生；会让所有已写好的加成第一次生效，需重标平衡 |
| **C2** P2 | 修「假引导」文案与机制背离 | 36 个节点 `reveal_summary` 已写、机制为 0：要么编译成 `reveal_condition`（B2），要么在生成阶段拒绝这种组合；「兵营会在每次经济结算后继续征召」这类与 `plan=0` 相反的状态描述，应由 `open_sum` 数值驱动而非固定句 | 生成脚本 + view model |

**改动层小结**：A1/A3/A5/B1/B2/B3/B4 主体在数据与脚本层（无需重编 C++）；A2/A4/C1 需要动原生公式或存档 schema。任何改 `units / equipment / supply / state_buildings / unlock_tech_ids` 的字段都会触发 `catalog_hash` 变化（`military_catalog_compiler.gd:874-936`；`military_core_save.cpp:636-637` 加载时校验），**旧 PKMI 存档需配套迁移**，不能只改数据。

---

## 7. 必须避免的误判（红队复核结果）

以下表述已被证据推翻或需降调，**不要写进后续设计/修复单**：

1. ❌「民兵随时代按 1.35^era 变强、era3/era5 反超正规军、等时代比研究军工划算」——查表 + `country_era` 恒 0，运行时恒 ×1.0，且不进实战。
2. ❌「装备完全不影响实战」——`condition_q16` 被补给维持率改写（`military_core_logistics.cpp:1887`）并被 `sum_lot_value` 读取（`military_core_war.cpp:156`），系数 0.75~1.0。准确说法是「**装备 goods 的质量与到货**不进公式」。
3. ❌「可交易 = 开局市场凭空出现 bows」——`trade_enabled` 只是权限；`initial_stock=0` 且无产能。
4. ❌「bows 的三个 technology_tags 是 AND / 要三层科技全齐才能产」——`cell_has_requirements` 是 ANY（`economy_runtime.cpp:5078-5080`）；层数来自 `composite_tools` 的硬前置闭包。
5. ❌「兵种解锁独立于科技树」——解锁位由 `country->has_technology()` 填充（`world_ext_military.cpp:970`）；缺的是**反向声明**。
6. ❌「军事科技无可观察差异 / 科技树完全没有引导」——25/36 有内容解锁、27/36 有 Modifier、35/36 有效果摘要；AI 宣战、兵额容量、预算配额、时代跃迁也都生效。失效的是发现/实践/回路层与跨目录绑定。
7. ❌「设计者没想到」——`branch.military_affairs`、`unit_unlock` 校验器、20 张军事理念卡、家族内容都在设计案里，属已规划未落地。
8. ❌「军事面板无全国兵额合计 / 无招募训练信息」——有「N 座 · 兵额 X」caption、逐格兵额/在驻/配额表、招募开关与训练表；缺的是资源对照与手动命令入口。
9. ❌「点 +5% 会产生一笔永远等装备的订单」——命令落库全 0，不产生订单；开局根本没有部队与订单。
10. ❌「开局初始部队全是民兵」——开局军事侧零兵；「一旦招募落的都是民兵 lot」才成立。
11. ❌「36 个军事节点没有 reveal_condition / 没有 branch_family」——字段 36/36 存在，只是前者全空、后者全为非军事族。
12. ❌ 仓库根 `military_core.cpp` / `military_core_save.cpp` 是第二套实现——两者是 0 字节空文件，行号一律以 `gdext/src/` 为准。

**可以强断言的核心**：`tech=""` 只有 militia 与 tribal_warriors 且恒解锁；`_compile_supply` 只认 Array/`"@ammunition"` 导致 upkeep/ammunition 候选为空、需求仍计入 need 而 satisfied 恒 0；装备质量/到货不进 `sum_lot_value`；训练下单即改兵种；`config.set` 字段名不匹配导致份额清零；开局 `posts=0 → plan=0` 不发招募；36 个军事节点 `reveal_condition` 全空、零里程碑候选、零军事应用交汇；跨目录审计只加载 EconomyCatalog 且 `maxi()` 钳掉反向断层。

---

## 8. 仍待运行验证的开放问题（静态代码不可判定）

1. 第 0 天 `has_policy` 为 true 还是 false（`configure_military` 开槽 vs `set_terrain` 触发 `reset_state` vs 首次 `run_military_daily` 重开槽的先后），两种情况下界面读数一致，但不影响结论。
2. `per_soldier_cost` / `daily_wage` / `soldiers_total` 的精确初值（依赖经济侧 `country_soldier_living_cost` 与 bootstrap lots）。
3. `equipment_ready` 只由 shipment 送达置 1，而同格直购分支只 `stock_add()` 不写该字段（`military_core_logistics.cpp:1330-1334`）——按代码推演会永久挂起，但需一次真实对局确认。
4. 空候选类对 `supply_ratio_q16` 的实际折损幅度（依赖 `scale`、地形修正、整数除法截断与 3 日 EMA），只能确认方向，不宜给无前提的百分比。
5. `unit_share_rows` 在 `tech_gate_known == false` 时放行全 24 单位（`military_view_model.gd:320-321`）——生产路径下 snapshot 正常，此边界是否可达需运行验证。

建议用 `PK_AUTOPLAY_PROBE=1 <godot_console> --headless --path .`（真实 `begin_new_game()`，泵帧 60–90 秒）跑一次，把上述 1–4 与 T0–T7 时序逐项对照；`pk::log_*` 走 stdout，需 `> /tmp/x.log 2>&1` 后 grep，编辑器 Output 看不到。

---

## 附：审查轮次与覆盖

| 轮次 | 子任务 | 主要产出 |
|---|---|---|
| 1 | 单位目录 / 军需产业链 / 科技树拓扑 / 面板与地块页 / 原生数值运行时（5） | 24 兵种数值表、军需品→配方→解锁依赖表、开局供给清单、面板三张表、招募/维护/战斗函数级拆解 |
| 2 | 关键断言穿透复核 / 数值平衡推演 / 引导契约对照（3） | 推翻「多标签 AND」「开局有卡住的订单」；量化装备金额与研究点；项目自定引导契约 34 条 + (a)/(b)/(c) 规划分类 |
| 3 | 红队挑错 / 玩家开局时序复现 / 两份报告补全（3+） | 推翻「时代白嫖」、降调 8 条；确认 `+5%` 不生效与开局兵额 0；T0–T7 时序与跨系统操作链 |
