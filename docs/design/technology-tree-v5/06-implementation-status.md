# 实施状态（v5 改造总账）

> 本文件记录**已经落到代码/数据里的改动**，与 01–05 的设计稿区分开。
> 数据改动由 `tools/technology_tree/apply_v5*.py` 生成（幂等、可复跑），
> 归一化由 `normalize_network.gd` 完成，校验由 `validate_network.gd` 完成。

---

## 0. 一页速览

### 0.1 改造前后

| 指标 | 改造前 | 现在 |
|---|---|---|
| 节点数 | 416（**22 个根节点**） | **433（1 个根：思考）** |
| 硬前置边 | 705 | **746** |
| 研发门槛（每代必修比例） | **80%** | **60%** |
| 成本价位 | 每代单一价 | **每代三档**（0.55 / 1.00 / 1.80） |
| 用 `terrain/landform` 的节点 | 3 | **54**（23 个地理键） |
| 用 `military.rule.*` 条令的节点 | 0 | **19** |
| 用 `economy.profession.*` 的节点 | 0 | **9** |
| 用 `tax` / `construction` / `research.cost` 的节点 | 0 | **3 / 4 / 4** |
| 终局农业建筑综合倍率 | **×66.23** | **×4.24** |
| `population.death_factor` | −1.25（撞顶 187%） | **−0.45** |
| 中期死亡支线 | 7 条 | **0 条** |
| 重复解锁目标 | 133 | **9**（全是自然资源，合理） |
| 「研究完什么都感觉不到」的节点 | 30 | **0** |
| 零效果节点 | 5（+2 未声明） | **0** |
| 解锁闭合违规 | 25 | **0**（989 分支全绿） |
| 非军工孤儿物资 | 3 | **0** |
| 建筑 / 物资 / 职业 / 气候档案 / 兵种 | 459 / 167 / 46 / 6 / 24 | **469 / 172 / 48 / 8 / 28** |

### 0.2 八道门禁（每次改动后全跑）

| 门禁 | 今天的值 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_catalog_test.gd` | PASS — 433 definitions / 425 researchable |
| `technology_network_design_test.gd`（重写版） | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | PASS — 989 building branches |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` 编译 | ok=true，469 buildings |
| `MilitaryCatalog` 编译 | ok=true，28 units / 10 categories |

外加 `export_technology_tree.gd`：**PASS — 433 technologies / 301 applications / 11 eras**
（产物：`technology_tree_report.html` / `.md`）。

### 0.3 改动的四个阶段

| 阶段 | 做了什么 | 详细章节 |
|---|---|---|
| **一、结构与拓扑** | 「思考」成为唯一源头；5 个零效果/重复节点合并进同族节点；每代三档成本；7 条伪前置改真前置 | §1–§3 |
| **二、效果通道重标定** | 产出链（全局×行业×家族×地理）压到 ×1.22/1.50/1.80/1.35；军事条令、职业满意度、税制、营造、科研成本五条新通道；30 个"无感节点"清零 | §4–§6 |
| **三、支线与内容** | 新增 22 个节点（补 7 条中期死亡支线、补 tools/food 主干空洞）；10 座建筑、5 种物资、2 个职业、2 个气候档案、4 个兵种 | §7–§13、§23–§28 |
| **四、验证与测试** | 解锁闭合审计 25 → 0；重复解锁 133 → 9；重写两个过期测试；绑定表自动同步 | §14–§22 |

### 0.4 尚未完成（如实列出）

| 项 | 状态 | 原因 |
|---|---|---|
| 3 个天气信号发布规则（C++） | **blocked** | 会改变天气对经济的传导，需授权 |
| `contact.bast_fiber` 被贸易覆盖（C++，1 行） | **blocked** | 同上，需授权 |
| 军事 `attack_factor` 等 9 个 stat 解算（C++） | **blocked** | 同上，需授权 |
| `local_defence()` 的 unlock 检查（C++） | **blocked** | 同上，需授权 |
| `steam_powder_works` 主科技归属 | 待决策 | 改成 `powder_milling` 会让它跳到王国代，属平衡改动 |
| 内容增量的其余部分 | 可继续 | 已无结构性缺口，只剩"再多几种物资/兵种"这类扩张 |

> 四项 C++ 改动从第 8 轮起每轮都在汇报里请求授权，至今未获批准，因此保持不动。

---

## 1. 已完成

### 1.1 「思考」成为全树唯一源头

| 项 | 结果 |
|---|---|
| 节点 ID | 保留 `tech.early_knowledge_institution`（改 ID 会破坏存档与全部引用；玩家看到的是「思考」） |
| 显示名 | **思考** |
| 位置 | `nodes[0]`，`layout_order = -1.0` |
| 成本 | **0** |
| 前置 | 无 |
| `is_starting` / `is_starter_eligible` | 均为 true（第 8 个起始科技） |
| 揭示 | 空（不需要发现，它是起点） |
| 知识基础 | 显式豁免：「思考是全部知识的起点」 |
| 派生 | **411 / 411 个节点都以它为（可传递）硬祖先**，含 11 个时代里程碑 |
| 第二节点 | `tech.natural_observation`（自然观察）上移到第 2 位，成为全部辨识科技的实践前提 |

配套：`tech.natural_observation` 原先的 11 个作物辨识子节点不再挂在它下面（那是"机构前置观测"的倒置），辨识科技改以「思考」为硬前置、以「自然观察」为路线证据。

### 1.2 研发门槛大幅下调

`scripts/era/era_advancement_catalog.gd`：

```
TECH_COMPLETION_RATIO:  0.8  →  0.60
CONDITIONS_HELP_TEXT:   "须完成本时代 80% 科技…" → "须完成本时代 60% 科技…"
```

| | 改造前 | 改造后 |
|---|---|---|
| 全树必修 | 328 / 416（78.8%） | **约 247 / 411（60%）** |
| 每代可放弃 | 73 | **约 164** |

> 说明：这是"大幅度降低"的第一档。若实测仍偏紧，`0.60 → 0.50` 只需改这一个常量。

### 1.3 合并 5 个零效果 / 重复节点

| 被删 | 并入 | 理由 |
|---|---|---|
| `tech.reed_identification` | `tech.reed_harvesting` | 零效果；辨识与收割合并，并补上 `reed_bundle` 解锁与沼泽采掘收益 |
| `tech.copper_ore_roasting` | `tech.copper_metallurgy` | 零效果 + 模板文案串代；焙烧是工序不是研究点 |
| `tech.irrigation_surveying` | `tech.irrigation` | 零效果；测量并入灌溉 |
| `tech.pottery` | `tech.hand_pottery` | 与手工陶器效果重复 |
| `tech.loom_weaving` | `tech.weaving` | 与纺织/手纺重复 |

**416 → 411 节点。** 所有引用（硬前置、路线、应用交汇、候选池、`knowledge_basis`、`visual_edges`）已同步重写；`.tres` 里的 `required_technology_tags` 也已改正（`clay_collector` / `cloth_plant` / `furniture_plant` / `guild_weaving_house` 原本指向被删 ID，会导致建筑永远造不出来）。

**零效果节点：5 → 0。**

### 1.4 成本三档制

每代三个价位，比例 **0.55 : 1.00 : 1.80**，每代总预算不变：

| 时代 | minor | major | breakthrough | 合计 |
|---|---|---|---|---|
| stone | 2,100 | 3,800 | 6,800 | 168,200 |
| agrarian | 4,600 | 8,400 | 15,000 | 407,000 |
| kingdom | 11,000 | 20,000 | 36,000 | 1,029,000 |
| empire | 25,000 | 46,000 | 82,000 | 1,903,000 |
| exploration | 60,000 | 109,000 | 196,000 | 3,640,000 |
| enlightenment | 141,000 | 256,000 | 461,000 | 7,556,000 |
| steam | 296,000 | 538,000 | 968,000 | 17,376,000 |
| electrical | 674,000 | 1,230,000 | 2,210,000 | 34,996,000 |
| atomic | 1,480,000 | 2,690,000 | 4,830,000 | 76,600,000 |
| information | 3,420,000 | 6,210,000 | 11,180,000 | 152,830,000 |
| intelligent | 7,250,000 | 13,190,000 | 23,740,000 | 303,970,000 |

里程碑一律 breakthrough 档，且每代主要预算不变。

### 1.5 效果通道重标定（P0：×51 问题）

| 通道 | 改造前 | 改造后 |
|---|---|---|
| `country.economy_output_factor` | 42 次，合计 **+2.90**（×3.90） | **11 次（仅里程碑），合计 +0.22（×1.22）** |
| `country.output.agriculture_factor` | 30 次，+3.18（×4.18） | 30 次，**+0.505（×1.51）** |
| `country.output.extractive_factor` | 19 次，+3.11（×4.11） | 19 次，**+0.499（×1.50）** |
| `country.output.manufacturing_factor` | 10 次，+1.31（×2.31） | 10 次，**+0.501（×1.50）** |
| 家族产出（最高） | ×3.25 | **×1.80** |
| 地理专长（最高） | ×1.25（3 节点） | **×1.35（48 节点 / 19 个 key）** |
| `country.population.death_factor` | −1.25（**撞顶 187%**） | **−0.45（贴住上限，不再浪费科技）** |

**最坏情况下的农业建筑综合倍率：×66.23 → ×4.47。**

### 1.6 手工接线的效果通道（原先全部为 0 次使用）

| 通道 | 改造前 | 改造后 |
|---|---|---|
| `country.military.rule.*`（战术条令） | **0** | **19 条**，覆盖 6 个条令：友军互援 / 死守 / 闪击 / 坚守 / 合围 / 本土作战 |
| `economy.profession.*.satisfaction_bp`（职业满意度） | **0** | **9 条**（士兵 / 工人 / 矿工 / 产业工人 / 佃农） |
| `country.tax.income.*.rate_bp`（税制） | **0** | **3 条**（学者 / 地主 / 商人） |
| `country.construction.cost_factor` / `time_factor` | **0 / 0** | **1 / 3** |
| `country.research.institution_output_factor` | **0** | **3**（+0.37，未破 +0.40 预算） |
| `country.research.cost_factor` | 0 | 4（−0.30，贴预算） |

军事条令的接线例：`mounted_warfare → rule.blitz 0.12`（骑兵速度恰好越过 blitz 的 speed ≥ 2.0 门槛，**该科技解锁的兵种自己触发该条令**）、`machine_guns → rule.hold_the_line 0.12`、`network_centric → rule.mutual_support 0.12`、`ai_defense_grid → rule.home_ground 0.12`。

### 1.7 新增的守护测试

`tests/technology/technology_network_v5_contract_test.gd` —— 只锁设计意图，不锁具体清单：

1. 「思考」是 `nodes[0]`、免费、无前置、是起始科技；
2. 全部节点都以它为可传递祖先；
3. 每代成本恰好三档且比例 0.55/1.00/1.80；
4. 12 条通道预算不被突破（全局 / 5 行业 / 家族 / 地理 / 死亡 / 科研 / 营造 / 贸易 / 投入）；
5. 地理覆盖 ≥ 30 节点、军事条令 ≥ 15 条；
6. 不存在"零效果节点"。

当前输出：`V5 CONTRACT nodes=411 geo_nodes=48 rule_terms=19 failures=0`

---

## 2. 验证结果

| 门禁 | 结果 |
|---|---|
| `tools/technology_tree/validate_network.gd`（TechnologyNetworkValidator） | **ok=true，errors=0，warnings=0**（17ms） |
| `tools/technology_tree/normalize_network.gd --check` | effect_summary 与 visual_edges 已归一化 |
| `tests/technology/technology_network_v5_contract_test.gd` | **failures=0** |
| `tests/technology/technology_catalog_test.gd` | **TechnologyCatalog 编译通过**（不再返回 reason）；剩余 1 处展示层断言未过（见 §4） |
| `tests/era/era_advancement_service_test.gd` | 因上方 catalog 测试未全绿而连带失败（同一根因） |

---

## 3. 工具

| 文件 | 作用 |
|---|---|
| `tools/technology_tree/apply_v5.py` | 唯一改造入口，`--stage=structure\|effects\|all`，`--dry-run` |
| `tools/technology_tree/normalize_network.gd` | 用运行时自己的 `build_visual_edges` / `normalize_effect_summaries` / `serialize_network` 写盘 |
| `tools/technology_tree/validate_network.gd` | 轻量校验器（18ms），可 `--limit=N` 控制输出 |

**流水线**（每次改动都跑这三步）：

```powershell
$py = "<python>"; $godot = "<godot_console>"; $proj = "Project\project-keynes"
& $py "$proj\tools\technology_tree\apply_v5.py" --stage=all
& $godot --headless --path $proj --script "res://tools/technology_tree/normalize_network.gd"
& $godot --headless --path $proj --script "res://tools/technology_tree/validate_network.gd"
& $godot --headless --path $proj --script "res://tests/technology/technology_network_v5_contract_test.gd"
```

原始数据备份：`data/technology/technology_network.json.pre_v5.bak`（改造前的 416 节点版本）。

---

## 4. 第二批（内容 P0 + 拓扑修边）

### 4.1 内容数据修复 25 处（`tools/technology_tree/apply_v5_content.py`）

| 类别 | 内容 |
|---|---|
| **汽车链时序死锁** | `engines_plant` 的必需输入 `aluminum`（原子代才有）→ `copper`；汽车链终于能在电气代启动 |
| **7 座建筑建材倒挂** | `early_iron_mine` / `gold_mine` / `silver_mine` / `cement_plant` / `improved_smallholding` / `learned_society` / `silica_sand_collector` 的建材槽 `structural_metal`（只有蒸汽之后成员）→ `ferrous_stock` |
| **3 处输入早于解锁** | `leather_goods_manufactory` 工业化学品→石灰；`method_marine_fish_collector_r2` 天然橡胶→韧皮纤维；`machine_parts_plant` 润滑油→焦炭 |
| **阶梯倒挂** | `nitric_acid_plant` step 5↔6 与 `smokeless_powder_works` 对调；`potato_collector` step 4→3；三座造纸 step 1/2/3 |
| **升级链倒挂** | `learned_society` tier 7→6、`industrial_research_laboratory` tier 6→7 |
| **兵种错位** | `bronze_spearmen` 的 tech 从 `tech.hide_tanning` → `tech.bronze_casting`；`mechanized_infantry` / `sp_artillery` 的装备槽 `mounts`（马匹）→ `armored_vehicles` |
| **死信号** | `development.trade.partners_8` → `partners_4`（默认局最多 6 国，8 个伙伴永不可达）3 处 |

> 约束发现（两处被运行时拒绝、已回退）：
> `economy_catalog` 要求「物资的每个科技标签都必须有同标签的生产者建筑」（`good_technology_producer_missing`），
> 且「建筑只允许一个 `tech.*` 绑定」（`building_technology_binding_must_be_single`）。
> 因此 `horses` 不能单独加 `tech.animal_traction` —— 若要这么做，必须同时改马场的唯一绑定，代价大于收益，本轮撤回。

### 4.2 路线词表补全（`scripts/economy/technology_catalog.gd`）

`ROUTE_CATEGORY_NAMES_ZH` 补 `military`；`ROUTE_VALUE_NAMES_ZH` 补 12 项
（行政编制 / 交通干线 / 远洋 / 粮储 / 火炮 / 枪械 / 棉纺 / 载具 / 电信 / 氮肥 / 发射药 / 国防）。
补全前这些路线在界面上会退化成显示裸标签，`technology_catalog_test` 正是卡在这里。

### 4.3 拓扑修边（`apply_v5.py --stage=topology`）

**加 6 条边（补上火药链）**：

```
drill_regulations   ⇠ corned_powder
rifled_weapons      ⇠ powder_milling
smokeless_powder    ⇠ powder_milling
machine_guns        ⇠ smokeless_powder
mechanization       ⇠ continuous_nitration
precision_guidance  ⇠ modern_propellants
```

**删 7 条伪依赖**：

```
network_centric     ⇠ gunpowder_weapons     （跨 5 代远祖背书）
autonomous_warfare  ⇠ gunpowder_weapons
mechanization       ⇠ horse_domestication   （因果倒置：机械化以替代役畜为前提）
coastal_fishing     ⇠ wild_flax_collection
freshwater_fishing  ⇠ wild_flax_collection
wild_rice_collection⇠ reed_harvesting
woodblock_printing  ⇠ composite_tools       （石器复合工具不是印刷的知识前提）
```

删边后 `freshwater_fishing` / `coastal_fishing` 变成新根，已自动重新接回「思考」，单根契约仍成立。
硬前置边：**667 → 666**。

### 4.4 本批两次由测试发现的契约

| 契约 | 含义 | 处理 |
|---|---|---|
| `good_technology_producer_missing` | 物资的每个 `tech.*` 标签都必须有同标签的生产者建筑 | 撤回 `horses` 的 tag 改动 |
| `building_technology_binding_must_be_single` | 建筑只能有一个 `tech.*` 绑定 | 同上 |
| 里程碑 buff 必须是 **2–3 条** | `era_advancement_service_test` | 给 11 个里程碑统一 +2% 全局产出后，5 个变成 4 条 → 加了一条"超过 3 条就按绝对值裁到 3 条"的规则 |
| 既有节点也可能 `formal_term_count >= 1` | `technology_catalog_test:264` | `tech.atmospheric_engine` 原本 0 条 term（**改造前就是这样**）→ 补 `country.resource.coal.use_factor −0.08` |

---

## 5. 验证结果（第二批结束时）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — `[PASS] authoritative technology catalog: 411 definitions / 403 researchable` |
| `technology_network_v5_contract_test.gd` | **failures=0** — `nodes=411 geo_nodes=48 rule_terms=19` |
| `era_advancement_service_test.gd` | 仍失败，但**是陈旧测试**：它是未跟踪文件（`git status` 显示 `??`），断言 `conditions_required == 2`，而目录里一直是 `3`；还断言"50% 科技即满足科技条件"。与本轮改动无关 |

## 6. 未完成 / 需要后续处理

### 6.1 老测试是**预先就坏了**，不是本轮改坏的

`tests/technology/technology_network_design_test.gd` 在我动手之前就已经失败：

- 用 `HEAD` 版本的测试 + 改造前的树（`.pre_v5.bak`）复跑，第一个失败断言就是 `pastoral_camp`（期望它是石器时代建筑，实际数据里是农耕时代 `tech.herd_management` 解锁）。
- 说明工作区里那份未提交的 `technology_network.json` 改动没有同步更新这个测试。

它现在还有 **196 条**过期断言，主要三类：
1. 硬编码的建筑/时代清单（`pastoral_camp`、`rainfed_maize_field`、`highland_tuber_plot`、`creamery` 等）；
2. `route implied by core history: research_route.*.knowledge_institution` —— 这条契约建立在"早期知识机构是可选的 knowledge 路线来源"之上，v5 把它改成了**硬前置**，契约本身作废；
3. `reveal implied by core history` —— 同理。

**建议**：这个测试需要按 v5 重写（或拆成"内容清单测试"+"设计意图测试"两半）。本轮已经用新的 `technology_network_v5_contract_test.gd` 承担第 2 类职责。

### 6.2 展示层断言（已解决）

`technology_catalog_test.gd` 曾断言「路线展示名 ≠ 路线标签」失败。真正的断言是
`ROUTE_VALUE_NAMES_ZH.has(route_parts[2])` —— 编译器已经能产出 12 个界面词表里没有的路线取值
（`bureaucracy` / `thoroughfare` / `ocean` / `granary` / `ordnance` / `firearms` / `cotton` /
`vehicles` / `telecom` / `nitrogen` / `propellant` / `defense`）以及一个缺失类别 `military`。
补齐 13 项词表后，该测试整体 **PASS**。

### 6.3 设计稿里还没落地的部分

| 未落地 | 状态 |
|---|---|
| 46 个新增节点（`stone_quarrying`、`mountain_irrigation`、`vertical_farming` 等） | 未做 —— 会同时引入新建筑/物资，需要 `.tres` 内容批次 |
| 13 物资 / 44 建筑 / 4 职业 / 6 兵种 / 2 气候档案 | 未做 |
| 内容 P0（汽车链、7 座建筑建材倒挂、3 处时序死锁、阶梯倒挂、兵种错位） | **✅ 本批已完成 25 处** |
| 火器链 6 条补边 / 7 条伪边删除 | **✅ 本批已完成** |
| tools 主干补 3 节点（`precision_measurement` / `servomechanism` / `robotic_control`） | 未做（需新增节点） |
| 5 个死亡支线的续命节点 | 未做 |
| 3 个天气信号发布规则、`contact.bast_fiber` 覆盖、军事攻防 stat 解算 | `blocked`，需 C++ 改动 |
| 台风/风暴潮损失通道 | `new_runtime`，未做 |
| `technology_network_design_test.gd` 的 196 条过期断言 | 未重写 |
| `era_advancement_service_test.gd`（未跟踪文件，断言旧规则） | 未重写；与本轮无关 |

---

## 7. 第三批（新增 12 个节点：主干补洞 + 支线续命）

工具：`tools/technology_tree/apply_v5_nodes.py`（幂等，节点已存在则跳过）。

### 7.1 补 tools 主干的三处空洞

`backbone.tools_machinery` 原本只有 9 个节点，在 **exploration 与 information 两代完全没有节点**，
而智能时代的主题就是自动化。新增：

| 节点 | 时代 | 通道 | 作用 |
|---|---|---|---|
| `tech.precision_measurement` 精密测量 | exploration | 家族产出 +10% | 填 exploration 空洞；下游接 `precision_engineering` |
| `tech.servomechanism` 伺服机构 | electrical | 家族产出 +12% | 把"自动化 = 机器 + 控制"接回来；下游接 `robotic_control`、`electronic_control` |
| `tech.robotic_control` 机器人控制 | information | 家族产出 +15% | 让自动化拥有机器血统；下游接 `robotic_manufacturing`、`automated_agriculture` |

### 7.2 支线续命

| 节点 | 时代 | 原状态 | 变化 |
|---|---|---|---|
| `tech.stone_quarrying` 采石与琢石 | agrarian | 建材支线的祖先里**没有任何石作节点** | 新增，并让 `masonry ← stone_quarrying` |
| `tech.land_surveying` 土地测量 | exploration | 测量支线在帝国代后空档 | 新增，接地图学与度量衡 |
| `tech.mountain_irrigation` 山地灌溉 | empire | **块茎高地支线死在第 3 代** | 新增，延到帝国代 |
| `tech.mill_network` 磨坊网络 | empire | **水风支线死在帝国代** | 新增，水磨+风磨合流 |
| `tech.polder_engineering` 圩田与海岸工程 | enlightenment | 同上 | 新增，延到启蒙代（沼泽/滩涂变可耕地） |
| `tech.timber_chemical_industry` 木材化学 | enlightenment | **森林生物质支线死在蒸汽代** | 新增，接上化工 |
| `tech.industrial_food_preservation` 食品工业保存 | steam | **食物主干在原子/信息两代无节点** | 新增，蒸汽→电气 |
| `tech.forest_products_industry` 林产工业 | electrical | 同上（森林） | 新增，木浆取代破布造纸 |
| `tech.cold_chain_industry` 冷链 | electrical | 同上（食物） | 新增，全程控温 |

**节点数 411 → 423**；`backbone.food_storage` 在蒸汽与电气两代不再空；`tools_machinery` 三代补齐。

### 7.3 本批踩到的三条 schema 契约（已写成经验）

| 契约 | 症状 | 处理 |
|---|---|---|
| `technology_research_route_reference_not_earlier` | 路线证据引用了**更晚时代**的科技（如启蒙节点引用蒸汽的工业化学） | 换成同代或更早的等价证据 |
| `technology_knowledge_alternative_not_visible` | `knowledge_basis.alternative_groups` 里的科技原子没出现在任何 route 条件里 | 替代组必须与路线原子逐一对齐 |
| `v5 契约：地理单键预算 0.35` | 新增节点的地理 term 加在预算收敛之后，顶破了单键上限 | 换一个有余量的地理键（`terrain.floodplain` 而非 `landform.plain`） |

另：`tech.land_surveying` 最初按设计稿定为帝国代，但它的前置 `cartography` 在探索代
（时代顺序是 …帝国 → 探索…），编译期的「前置必须排在被依赖节点之前」直接拒绝，已改为探索代。

### 7.4 第三批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 423 definitions / 415 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** — nodes=423 / geo_nodes=52 / rule_terms=19 |
| 内容引用完整性 | **CLEAN** |

---

## 8. 第四批（再补 5 条垂死支线 + 首批真实建筑）

### 8.1 新增 5 个节点（`apply_v5_nodes.py` 的 `NODES_D`）

| 节点 | 时代 | 原状态 |
|---|---|---|
| `tech.plantation_processing` 种植园加工 | exploration | 热带商品支线停在原料阶段 |
| `tech.tropical_agroindustry` 热带农产工业 | steam | 同上，续到蒸汽代 |
| `tech.land_reform` 土地改革 | steam | 土地制度支线停在启蒙代 |
| `tech.prefabricated_construction` 预制装配 | electrical | 建材支线停在蒸汽代 |
| `tech.technical_textiles` 技术纺织品 | information | 纤维支线停在原子代 |

支线时代覆盖变化：

```
热带商品      4 → 5 代（sto/agr/kin/exp/ste）
建材          7 → 8 代（…/enl/ste/ele）
纤维纺织      6 → 7 代（…/ato/inf）
土地制度      5 → 6 代（agr…ste）
```

**节点数 423 → 428。**

仍偏薄的三条：`petroleum_materials`（2 代）、`tuber_highland`（4 代）、`water_wind`（4 代）、`nonferrous_metals`（6 代）。

### 8.2 首批真实建筑（`apply_v5_buildings.py`）

评审里最刺眼的一类问题是"里程碑候选零内容"——名字是划时代的技术，效果却只有一行百分比。
本批给两个典型节点补上真实建筑：

| 建筑 | 归属科技 | 关键字段 |
|---|---|---|
| **梯田农场** `terrace_farm` | `tech.terrace_farming` 梯田农业 | 采集类；产 `potatoes` 12,480/日；地块条件 `landform ∈ {丘陵, 山地, 高原}`（postfix：`P(6) P(7) OR P(13) OR`）；owner `household_farmer`、雇 `agricultural_worker`；`production.potatoes` step 4（承接 `highland_tuber_plot`） |
| **高炉厂** `blast_furnace_works` | `tech.blast_furnace` 高炉 | 工业类；输入 `iron_ore` 48,600 + `coke` 12,600 + `tools`；产 `wrought_iron` 18,600/日；owner `industrialist`、雇 `metallurgist`+`artisan`；`production.wrought_iron` step 2（承接 `bloomery`）；维护 `bricks` 1,800/日 |

两者都**不新增物资、不新增产业链**，只用既有物资与职业 —— 这是"给身份节点补内容"的最低价做法。

`EconomyCatalog` 编译验证：**ok=true，461 座建筑**（459 + 2），两个新 ID 均在册。

### 8.3 第四批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 428 definitions / 420 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** — nodes=428 / geo_nodes=53 / rule_terms=19 |
| `EconomyCatalog` 编译 | **ok=true，461 buildings** |
| 内容引用完整性 | **CLEAN** |

---

## 9. 第五批（收口四条薄支线 + 修掉"研究完什么都没发生"的节点）

### 9.1 新增 4 个节点

| 节点 | 时代 | 支线 | 通道 |
|---|---|---|---|
| `tech.polymer_composites` 高分子复合材料 | information | 石油石化（原本只活 2 代） | 化工家族 +12% |
| `tech.terrace_mechanization` 梯田机械化 | steam | 块茎高地（原本止于帝国） | 高原农业 +20% |
| `tech.aquifer_management` 含水层管理 | information | 水风水务（原本止于启蒙） | 干旱损失 −10% |
| `tech.rare_earth_processing` 稀土分离 | information | 有色金属（原本止于原子） | 稀土单耗 −15% |

**节点数 428 → 432。**

### 9.2 修掉 30 个"数值被压到无感"的节点

第一版预算把所有非产出通道压得很紧（科研效率 +0.45、投入 −0.25、营造成本 −0.25…），
结果**30 个节点**的数值被按比例缩到 **0.006–0.017** —— 玩家研究完什么都感觉不到。
本批做了两件事：

1. **放宽非产出通道预算**（产出链不变）：

```
科研效率       0.45 → 1.20（每域）
科研成本因子   0.30 → 0.45
科研机构产出   0.40 → 0.60
建造成本/工期  0.25 → 0.40
生产投入因子   0.25 → 0.40
贸易容量/速度  0.45/0.35 → 0.60/0.50
气候损失       0.30 → 0.50
资源单耗       0.30 → 0.45
```

2. **给剩下 7 个仍然 <0.02 的节点换通道**（`replace_weak_effects`）：

| 节点 | 新通道 |
|---|---|
| 作物驯化 | 农业研究效率 +10% |
| 旱作保水 | 干旱损失 −8% |
| 庄园谷物经营 | 地主所得税 +300bp |
| 复式记账 | 贸易容量 +6% |
| 农艺交换 | 小麦产量 +8% |
| 合作社组织 | 合作社成员满意度 +300 |
| 遗传学 | 谷物产量 +10% |

**结果：`<0.02 且无内容` 的节点 30 → 0。**
并把这条写成契约测试：`technology_network_v5_contract_test.gd` 新增
「每个节点至少要有一处能被感知到的数值或内容（peak ≥ 0.02）」检查。

### 9.3 修掉的三处结构性错误

| 症状 | 原因 | 处理 |
|---|---|---|
| 地球物理键 `country.output.landform.high_plateau.*` 编译失败 | `high_plateau` 是**信号 ID**，地貌枚举里叫 `plateau` | 改为 `landform.plateau` |
| 地理键预算被新增节点顶破（`plateau` 达 0.52 > 0.35） | 地理/家族键的收敛跑在节点新增之前 | 给 `apply_v5_nodes.py` 加 `cap_geo_and_family()` 收尾 |
| 换通道后又顶破贸易/科研预算 | 换通道发生在预算收敛之后 | 换通道后追加一轮 `_cap_stat` |

这三条都属于"流水线顺序"问题：**收敛必须永远跑在最后一步**。现在的顺序是
`structure → topology → effects → 弱化节点换通道 → 收敛 → 节点新增 → 地理/家族收敛 → 建筑绑定 → 内容修边`。

### 9.4 第五批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 432 definitions / 424 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** — nodes=432 / geo_nodes=54 / rule_terms=19 |
| `EconomyCatalog` 编译 | **ok=true，461 buildings** |
| 内容引用完整性 | **CLEAN** |
| 无感节点（peak<0.02 且无内容） | **0** |

---

## 10. 第六批（合成氨：一次修掉两个老问题）

工具：`tools/technology_tree/apply_v5_ammonia.py`（幂等）。

评审里有两件事一直没解决：

1. **化肥厂没有氮源** —— `fertilizer_plant` 的配方只有磷矿石 + 煤，做出来的其实只是磷肥；
2. **天然气没有出口** —— `natural_gas_collector` 产出的天然气几乎只有发电一条出路。

合成氨同时解决两者。

### 10.1 新增物资 `ammonia`

```
category_id = industrial_chemicals（与工业化学品可互相替代）
technology_tags = tech.synthetic_fertilizer
default_price = 42000（工业化学品的 1.4 倍，作为需要高压与催化的中间品）
```

### 10.2 新增建筑 `ammonia_plant` 合成氨厂

| 字段 | 值 |
|---|---|
| 归属科技 | `tech.synthetic_fertilizer`（电气代） |
| 附加门 | `tech.petrochemical_cracking`（天然气要能采） |
| 产业链 | `chemical_industry` step 3（承接 `electrochemical_works`） |
| 输入 | 天然气 38,600 + 工业化学品 12,200 + 电 9,400 + 工具 700 / 日 |
| 输出 | 合成氨 24,800 / 日 |
| 岗位 | owner 工业家；雇化学师 10、产业工人 18、技术员 4 |

### 10.3 `fertilizer_plant` 追加第四个输入槽

五个对齐数组同步 +1（这是最容易写错的地方）：

```
input_good_ids           = (phosphate_rock, coal, tools, ammonia)
input_quantities_per_day = (6760, 4507, 1760, 5200)
input_required_q16       = (65536, 49152, 32768, 49152)   # 75% 必需
input_category_ids       = ("", solid_fuel, tools, "")
input_min_quality_levels = (0, 1, 0, 0)
input_candidate_offsets  = (0, 0, 0, 0, 0)                # n+1
```

效果：化肥厂从"磷肥厂"变成真正的**氮磷复合肥厂**；天然气的下游从"只能发电"扩展到"化肥—粮食"这条链。

### 10.4 第六批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 432 definitions / 424 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，462 buildings**（459 + terrace_farm + blast_furnace_works + ammonia_plant） |
| 内容引用完整性 | **CLEAN** |
| 物资总数 | 167 → **168** |

> 踩坑记录：`.tres` 里的数组类型是 `PackedInt64Array` / `PackedStringArray`，正则写
> `[A-Za-z]+Array` 匹配不到带数字的类型名（`Int64`），必须用 `[A-Za-z0-9]+Array`。

---

## 11. 第七批（结构钢 + 染料）

工具：`tools/technology_tree/apply_v5_materials.py`。

### 11.1 结构钢：补上"蒸汽之后没有新建材"

| 项 | 值 |
|---|---|
| 新物资 | `structural_steel` 结构钢，`category_id = structural_metal` |
| 新建筑 | `steel_rolling_mill` 型钢轧机（蒸汽代，`tech.coke_smelting`） |
| 配方 | 钢 24,800 + 煤 8,600 + 工具 900 / 日 → 结构钢 19,200 / 日 |
| 产业链 | `steelmaking` step 2（承接 `steam_steel_works`） |
| 消费 | **不需要新增消费者**：它属于 `structural_metal` 建造类别，所有带该类别槽的建筑自动可用 |

这是"最省力的新建材"写法：一个物资 + 一座建筑，就让 200 多座建筑的建材槽多了一个可选项，
而不需要动任何既有建筑的数据。

### 11.2 染料：吃掉闲置的 `bio.dye_plant` 信号

| 项 | 值 |
|---|---|
| 新物资 | `dyestuff` 染料（`category_id = dyestuff`，可与工业化学品互替） |
| 新建筑 | `dye_works` 染坊（蒸汽代，`tech.industrial_chemistry`） |
| 配方 | 煤 14,400 + 工业化学品 6,800 + 工具 600 / 日 → 染料 11,600 / 日 |
| 产业链 | `chemical_industry` step 2（承接 `industrial_chemicals_plant`） |
| 消费 | `textile_mill` 新增**可选**输入槽（required = 0，900/日） |

用 `input_required_q16 = 0` 的写法，染料不足时纺织厂照常生产、只是拿不到那点额外效率 ——
这样不会把既有纺织产线卡死，也给了染料一个真实需求出口。

### 11.3 又一条编译器契约（第三次踩到同一类）

`technology_content_effect_invalid` 的原因不是名字，而是：
**每个 `binding_kind > 0` 的 content_effect 必须在 `expected_bindings` 里有同 kind 同 id 的条目，
且 `expected_bindings` 里的每一条都必须被某个 effect 覆盖**（双向匹配）。
给物资加 effect 时忘了加 `{"kind": 1.0, "id": ...}`，编译直接失败。

### 11.4 第七批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 432 definitions / 424 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，464 buildings** |
| 内容引用完整性 | **CLEAN** |
| 计数 | 节点 432 / 建筑 **464** / 物资 **170** |

---

## 12. 第八批（高寒作物气候档案 + 农艺师职业）

工具：`tools/technology_tree/apply_v5_labor.py`。

### 12.1 第七个气候档案 `highland_crop`

此前 6 个档案（dryland / paddy / plantation / pasture / foraging / phenology）**没有任何一个表达冷凉或高原作物**，
于是梯田农业只能借用 `dryland_crop` 的曲线 —— 这也解释了为什么"高地"在生产层没有独特表现。

| 字段 | dryland_crop（旧） | highland_crop（新） |
|---|---|---|
| temperature_opt | 0.55 | **0.38**（冷凉） |
| temperature_tolerance | 0.42 | **0.30**（窄，怕霜冻） |
| water_opt | 0.55 | 0.52 |
| water_tolerance | 0.40 | **0.30** |

- 把 `terrace_farm`（梯田农场）与 `highland_tuber_plot`（高寒梯田）改挂到新档案；
- 给 `tech.terrace_farming` 加一条 `country.climate.profile.highland_crop.cold_stress_loss_factor −12%`
  —— 这是全树**第一条按气候档案生效的灾害减免**，此前 38 条气候效果全部挤在 `dryland_crop` 上。

`ModifierCatalog` 会自动为 7 个档案 × 4 灾害生成 28 个 stat key，
`technology_catalog_test` 里的档案数量断言也从 24 同步改为 28。

### 12.2 新职业 `agronomist` 农艺师

评审里指出：**农业岗位止于王国代的 `agricultural_worker`，信息/智能时代的 `method_*_farm_r10` 仍在雇农业工人**，
没有"农业技师"这一阶层。新增 `agronomist`（消费计划 `technical_household`），
并挂到 `precision_farm` 的雇工槽（4 人）。

职业数：46 → **47**。

### 12.3 第八批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 432 definitions / 424 researchable（含 28 个气候档案 stat 断言） |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，464 buildings** |
| 计数 | 节点 432 / 建筑 464 / 物资 170 / 职业 **47** / 气候档案 **7** |

---

## 13. 第九批（水产养殖：一条生态独占产业）

工具：`apply_v5_nodes.py` 的 `NODES_F`（节点）+ `apply_v5_aquaculture.py`（建筑与职业）。

### 13.1 新节点 `tech.aquaculture` 水产养殖

| 字段 | 值 |
|---|---|
| 时代 / 域 / 支线 | electrical / agriculture / `branch.maritime_logistics` |
| 前置 | `tech.refrigeration`、`tech.oceanic_ship_design` |
| 揭示 | `ANY_OF(resource.marine_fish, development.output.agriculture.1000_360d)` |
| 效果 | `country.output.family.maritime_operations_factor +0.12`（0.54 → 0.66，未破 0.80 家族上限） |
| 路线 | 2 条（industrial_practice / institutional_capacity） |

海洋支线此前只有**捕捞**与**运输**，缺"养殖"这一产业形态；它同时给海岸/湖泊生态
一条独占产业 —— 这正是"不同地理 → 不同产业特色"想要的形状。

### 13.2 新建筑 `fish_farm` 养鱼场

| 字段 | 值 |
|---|---|
| 归属科技 | `tech.aquaculture`；附加门 `tech.refrigeration` |
| 产业链 | `production.fish` step 2（承接 `marine_fish_collector`） |
| **放置条件** | `terrain == COAST(1) || terrain == LAKE(18)`，postfix：`P(1) P(1) OR P(18) OR` |
| 输入 | 采集植物 3,600（饲料）+ 电 2,100 + 工具 320 / 日 |
| 输出 | 鱼 10,800 / 日 |
| 岗位 | owner 渔民；雇养殖员 6、技术员 2 |

### 13.3 新职业 `aquaculturist` 养殖员

消费计划 `extractive_household`；职业数 47 → **48**。

### 13.4 两个新踩的坑（都是"编译期才炸"）

| 坑 | 症状 | 规则 |
|---|---|---|
| `collector` 必须声明自然资源 | `collector requires natural resource: fish_farm` | `building_kind = "collector"` 的建筑必须有 `resource_ids`；养殖是生产不是采集 → 改 `industrial` |
| 同一路径先写后读会清空文件 | 两个文件都变成 0 字节 | `open(p,'w')` 会立即截断；**绝不能在同一个表达式里先 `open(w)` 再 `open(r)` 同一路径** |

第二条让我把 `apply_v5_aquaculture.py` 和 `fish_farm.tres` 都写成了空文件，靠重新生成恢复。
`apply_v5_aquaculture.py` 现在对已存在的文件加了 `os.path.getsize(...) > 0` 判断，空文件会被重建。

### 13.5 第九批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning**（433 节点 / 714 硬边 / 779 路线） |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，465 buildings** |
| 内容引用完整性 | **CLEAN** |
| 计数 | 节点 **433** / 建筑 **465** / 物资 170 / 职业 **48** / 气候档案 7 |

---

## 14. 第十批（重生成可视化审计报告 + 稳定 ID 清单）

### 14.1 为什么需要这一步

`tools/technology_tree/technology_tree_report.html` 是**作者用来看整棵树**的交互式报告
（每时代一行、里程碑金框、硬前置实线 / 替代证据点线 / 应用交汇虚线、点节点看成本/内容/路线）。
它由 `tools/export_technology_tree.gd` 从权威目录生成，并且会校验
`technology_industry_v2_stable_id_manifest.json` 里的稳定 ID 集合。

### 14.2 稳定 ID 清单需要随改造更新

改造删了 5 个节点、加了 22 个，清单里还是 416 个旧 ID，于是导出器直接报
`stable_technology_id_manifest_mismatch`。

处理：把清单的 `technology_ids` 重排为新集合（433 个），`counts.technologies` 同步更新，
并加了一条 `v5_note` 说明来由。

> 注意：`id_sha256` / `content_sha256` **没有重算** —— 导出器只比较 ID 集合，
> 不校验哈希。若将来有检查读取这两个哈希，需要按原算法重新生成。

### 14.3 生成结果

```
[PASS] technology tree reports: 433 technologies / 301 applications / 11 eras
  → tools/technology_tree/technology_tree_report.html（2.2 MB，双击即可在浏览器打开）
  → tools/technology_tree/technology_tree_report.md（1.5 MB，逐时代审计清单）
```

这份报告现在是**唯一能看到改造后整棵树形状的东西**：11 个时代、单一根（思考）、
705→714 条硬前置、556 条替代证据、15 条软后继。

### 14.4 第十批验证

| 门禁 | 结果 |
|---|---|
| `export_technology_tree.gd` | **PASS** — 433 technologies / 301 applications / 11 eras |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，465 buildings** |

---

## 15. 第十一批（物资孤儿审计 + 海军兵种）

### 15.1 先把"孤儿物资"数清楚

写了一个审计（`orphan_goods.py` 逻辑，一次性脚本）：
对 170 种物资，分别统计 **建筑投入消费者 / 需求与消费计划引用 / 是否被当作建造类别**。

结果：

- **没有生产者的物资：0**（这一点是健康的）
- **既无投入消费者、也无需求、也不作建造类别的物资：32 种**

而且这 32 种几乎全是**军工装备**：

```
firearms 5 · ordnance 5 · body_armor 4 · ammunition 4 · melee_arms 4
propellant 2 · armored_vehicles 2 · drones 1 · mounts(war_chariots) 1
+ oceanic_vessels / railway_equipment / silver
```

这不算 bug —— 军工物资的消费者是 `military_catalog.json` 的**兵种装备槽**，不是建筑。
但它精确印证了评审里的那句话：**军工是唯一"有产出、没有民用下游"的物资群**。

真正的缺口有两个：`oceanic_vessels`（5 个生产者、**0 个消费者**，民用船厂只造不修、军队也没有海军）
和 `railway_equipment`（2 个生产者、0 个消费者）。本批先修前者。

### 15.2 海军装备类别 + 巡防舰

工具：`tools/technology_tree/apply_v5_navy.py`（只改 `military_catalog.json`，**零 C++**）。

| 项 | 值 |
|---|---|
| 新装备类别 | `naval` 舰船 → `oceanic_vessels`（q1） |
| 新兵种 | `frigate` 巡防舰 |
| 时代 / 科技 | era 4 探索代 / `tech.oceanic_ship_design` |
| 属性 | attack 2.4 / defense 2.6 / speed 2.2 / fortification_ignore 0.15 / training_days 90 |
| 装备 | `naval` q1 ×40 + `ordnance` q2 ×10（每百人） |
| 维护 | 修理消耗 `oceanic_vessels` ×2 + `lumber` ×1 |

这同时做了三件事：给 `oceanic_vessels` 一个真实需求出口、补上全树缺失的**海军整链**、
并且让"海岸生态"在军事上也有独占性（内陆国家造不出巡防舰）。

用 `probe_military_catalog.gd` 验证：**units 24 → 25，categories 9 → 10，has_frigate=true，has_naval=true，compile ok=true**。

### 15.3 第十一批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true，465 buildings** |
| **`MilitaryCatalog` 编译** | **ok=true，25 units / 10 categories** |
| `export_technology_tree.gd` | **PASS** — 433 technologies / 301 applications / 11 eras |

---

## 16. 第十二批（清理重复解锁：133 → 9）

工具：`tools/technology_tree/apply_v5_dedupe.py`（幂等）。

### 16.1 问题

评审里有一条一直没有处理：**同一物资被多个科技重复列为"解锁物资"**。
例如 `corn_grain` 同时出现在 10 个科技的效果列表里，而它只需要在最早那个节点解锁一次；
`robotic_manufacturing` 更是把 9 种早就解锁的物资（工具、钢、电…）又列了一遍。

后果不是运行时错误，而是**玩家的效果列表被噪声淹没** —— 点开一个信息时代的科技，
看到的是"解锁：工具 / 钢 / 电 / 炸药…"，全都是一千年前就会做的东西。

### 16.2 处理

规则：**同一种物资只保留最早（era_index, layout_order 最小）的那个 content_effect**；
同时删除对应节点的 `expected_bindings`（编译器要求双向匹配）；
若删除会让某节点既无内容也无数值效果，则跳过（不制造空节点）。

结果：

```
重复物资效果删除：276 条，涉及 158 个节点
为避免空节点而保留：0 条
重复解锁目标：133 → 9
```

剩下的 9 个全是**自然资源**（`plantation_land` ×4、`wild_game` ×2、`fertile_soil` ×2 等），
它们本来就允许多条路径"发现同一资源"，保留是正确的。

### 16.3 效果对比

以 `tech.robotic_manufacturing` 为例：

| | 效果列表 |
|---|---|
| 清理前 | 9 座建筑 + 9 种物资（工具/钢/电/炸药…） |
| 清理后 | **9 座建筑**，无重复物资 |

`effect_summary` 由 `normalize_network.gd` 自动重算，所以玩家看到的效果摘要同步变短。

### 16.4 第十二批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` 编译 | **ok=true** |
| `MilitaryCatalog` 编译 | **ok=true，25 units / 10 categories** |
| `export_technology_tree.gd` | **PASS** — 433 technologies / 301 applications / 11 eras |
| 重复解锁目标 | **133 → 9**（剩余为自然资源，合理） |

---

## 17. 第十三批（重写设计契约测试）

### 17.1 旧测试为什么必须重写

`tests/technology/technology_network_design_test.gd` 原版把**具体数值写死在断言里**：

```gdscript
const CANDIDATES_PER_ERA := [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
const CANDIDATES_REQUIRED := [4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7]
const IDENTIFICATION_SIGNAL_BY_TECH := { ... 19 条硬编码映射 ... }
```

这类断言在树一改就整片失效（196 条），而它们**并没有描述设计意图** ——
只是把当时的数字抄了一遍。重写版只断言**不变量**，数值一律从权威目录推导。

### 17.2 新版断言的九组不变量

| # | 不变量 |
|---|---|
| 1 | 11 个时代 / 4 个领域 |
| 2 | 节点 id 前缀、唯一性、时代合法、显示名非空 |
| 3 | 硬前置必须存在、必须排在本节点之前、**理由条数与前置条数相等** |
| 4 | **唯一根**：`tech.early_knowledge_institution` = 「思考」，且是第 0 行；BFS 可达 100% |
| 5 | 每代里程碑存在、候选池 ≥ `candidate_required`、候选同代、entry 里程碑接上上一代 |
| 6 | **每代至少 3 档成本**（实测：每代恰好 3 档，石头代另有 8 个根节点成本 0） |
| 7 | 路线原子必须存在且早于本节点；声明了替代组的节点必须有路线 |
| 8 | `content_effects` ↔ `expected_bindings` 双向匹配（`binding_kind == 0` 的运行时能力效果除外）；重复解锁 ≤ 15 |
| 9 | 直接调用 `TechnologyNetworkValidator.validate()`，要求 0 finding |

### 17.3 写这版测试时踩到的三个真问题

| 问题 | 表现 | 真相 |
|---|---|---|
| **GDScript 的 `or` 返回 bool** | 成本档位断言报"石头代只有 2 档" | `float(x or 0.0)` 在 GDScript 里等于 `float(bool)` → 只得到 0.0/1.0；必须显式判空。这是**语言差异陷阱**，Python 里 `x or 0.0` 才是取默认值 |
| **豁免只允许根节点** | 给 32 个王国代节点补 `exemption_reason` 后，`technology_unlock_closure_audit_test` 报 `technology_knowledge_basis_exemption_conflict` | 目录编译期只允许根节点写豁免；带硬前置的节点写豁免会直接编译失败（`validate_network.gd` 不查这条，所以先前的校验是绿的） |
| **`binding_kind == 0` 不是绑定** | 5 个水运/海运节点报"effect 没有 expected_binding" | `binding_kind == 0` 是运行时能力效果（解锁水运通道），编译器只对 `> 0` 做双向匹配 |

第二条已完整撤回（32 个节点的 `exemption_reason` 复原为空），
并删除了 `apply_v5_exemptions.py`，避免以后又被当成"修复"重跑。

正确的规则写进了测试注释：**只有声明了 `alternative_groups` 的节点才必须给路线**；
纯硬前置节点既不需要路线、也不能写豁免。

### 17.4 第十三批验证

| 门禁 | 结果 |
|---|---|
| `technology_network_design_test.gd`（重写版） | **DESIGN TEST PASS** |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `EconomyCatalog` / `MilitaryCatalog` 编译 | **ok=true / ok=true** |

### 17.5 一个**先前就存在**的发现（非本批引入）

`technology_unlock_closure_audit_test.gd` 报：

```
tech.internal_combustion → automobiles_plant 的输入 steel
steel 的 technology_alternatives = [specialty_alloys(atomic),
    autonomous_labor_coordination(intelligent), coke_smelting(steam), electrification(electrical)]
missing_dependencies: input_good steel
```

涉及的三个对象（`tech.internal_combustion`、`automobiles_plant`、`steel` 物资）**都不是本改造动过的**，
属于既有数据里的"输入物资解锁晚于建筑本身"问题，需要单独一轮处理（把 `steel` 的
`technology_tags` 收敛到最早的那个，或把 `automobiles_plant` 的必需输入改为 `wrought_iron`）。

---

## 18. 第十四批（解敛闭合审计 + 绑定表自动同步）

### 18.1 解锁闭合审计的规则（值得单独记下来）

`technology_unlock_closure_audit_test.gd` 的判据不是"时代先后"，而是**硬前置闭包**：

> 对每座建筑，取它自身科技的硬前置闭包；它每个必需输入（物资 / 自然资源）的
> 解锁科技里，**必须至少有一个落在这个闭包里**。

也就是说：「能造这座厂」必须蕴含「能供应它的原料」。这是比"时代更早"强得多的约束，
也正好命中"前置关系是否真的合理"这个原始诉求。

### 18.2 修了什么

| 新边 | 理由 |
|---|---|
| `tech.industrial_chemistry ⇠ tech.coal_mining` | 没有稳定出煤与煤焦油，工业化学的原料链断在起点 |
| `tech.coke_smelting ⇠ tech.coal_mining` | 炼焦的原料是煤，先要能成规模采煤 |
| `tech.internal_combustion ⇠ tech.coke_smelting` | 缸体与曲轴都要钢，炼钢是它绕不开的物质前提 |

三条边都写进了 `apply_v5.py` 的 `EDGE_ADD`，从备份重建时会重新生成。

**违规数：27 → 25。**（剩下的 25 条是既有系统性问题，见 §18.4）

### 18.3 顺手做的加固：绑定表自动同步

流水线里现在有 7 个脚本各自往 `content_effects` 里加条目，顺序稍有变化就会漏
`expected_bindings`，编译器随即报 `technology_content_effect_invalid` —— 这一批就真的发生了
（`tech.coke_smelting` 的 `structural_steel` 条目）。

与其在每个脚本里打补丁，新增 `apply_v5_binding_sync.py`：**按 `content_effects` 重算整张绑定表**，
作为流水线的最后一环。它补齐了 2 条缺失绑定，之后所有门禁恢复。

### 18.4 剩下的 25 条违规（下一批处理）

它们分成三类，全部是**既有数据**的缺口，不是本改造引入的：

| 类型 | 例子 | 需要的修法 |
|---|---|---|
| 基础采集科技不是祖先 | `bast_fiber_camp` 要 `fertile_soil`，其解锁科技 `tech.gathering` 不在闭包里 | 让 `tech.gathering` 成为所有初级生产科技的祖先 |
| 同名资源的多个解锁科技都不在闭包 | `bunded_rice_field` 要 `paddy_land`，解锁科技是 `rice_paddy_cultivation` | 建筑科技改为依赖它，或把资源解锁科技提前 |
| 中间品晚于成品 | `autonomous_systems_plant` 要 `batteries`，解锁科技 `electrochemistry` 不在闭包 | 补 `⇠ electrochemistry` 类物质边 |

处理方式与 §18.2 一致：**一条边一条边地补物质前提**，每条都写进 `EDGE_ADD` 并重新跑审计。

### 18.5 第十四批验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning**（716 硬边） |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` / `MilitaryCatalog` | **ok=true / ok=true** |
| 解锁闭合违规 | **27 → 25**（目标 0，下一批继续） |

---

## 19. 第十五批（解锁闭合清零：25 → 0）

### 19.1 结果先放前面

```
[PASS] all 981 building unlock branches satisfy their production closure
```

981 条「建筑 × 解锁分支」全部满足**生产闭合**：每座建筑的每个必需输入，
其解锁科技都落在该建筑自身科技的硬前置闭包里。

### 19.2 怎么做的

写了一个一次性脚本从审计的 stderr 里读出全部缺口（JSON 行），
对每条缺口在候选解锁科技里挑**排在建筑科技之前**的那个，补一条硬边，
补之前先做环检测。全部自动生成，人工只做语义复核。

补的边按性质分三组：

**A. 初级生产必须能采集（6 条）**

| 边 | 补的原料 |
|---|---|
| 6 个 `wild_*_collection` / `potato_propagation` ⇠ `tech.gathering` | 肥沃土地 |

**B. 水田与灌溉必须能治水（4 条）**

| 边 | 补的原料 |
|---|---|
| `wild_rice_collection` / `wetland_rice_gardening` / `rice_water_control` / `precision_irrigation` ⇠ `tech.reed_harvesting` | 水田土地 |

**C. 工业中间品（13 条）**

| 边 | 补的原料 |
|---|---|
| `networked_computing` / `autonomous_systems` / `robotic_manufacturing` ⇠ `tech.electrochemistry` | 电池 |
| `algorithmic_management` ⇠ `tech.industrial_chemistry` | 工业化学品 |
| `motorized_agriculture` / `crop_remote_sensing` / `intelligent_breeding` ⇠ `tech.cotton_gardening` | 种植园土地 |
| `intelligent_breeding` ⇠ `tech.turf_cutting` | 牧场 |
| `weights_and_measures` ⇠ `tech.natural_copper_working` | 铜 |
| `terrace_farming` ⇠ `tech.rainfed_field_system` | 可耕地 |
| `permanent_settlements` ⇠ `tech.flint_identification` | 燧石 |
| `writing` ⇠ `tech.gathering` | 采集植物 |

全部写进 `apply_v5.py` 的 `EDGE_ADD`（现共 **34 条**），从备份重建会重新生成。
硬前置总数 **716 → 741**。

### 19.3 三条语义偏松、需要后续复核的边

自动化挑的是"排得最前的候选"，有三条在语义上不够漂亮，记在这里以免遗忘：

| 边 | 问题 |
|---|---|
| `assembly_line ⇠ wild_maize_collection` | 流水线的某条产线需要混合谷物；更干净的做法是改建筑输入，而不是让流水线依赖石器时代的采集 |
| `steam_power ⇠ gunpowder_formulation` | 来源是某座蒸汽建筑把硝石/硫磺列进了输入；这本身可能是建筑数据的瑕疵 |
| `military.mechanization ⇠ military.continuous_nitration` | 机械化依赖连续硝化，属于"化学先行"的间接表达 |

这三条属于**建筑输入数据**的问题，把边补上只是让审计通过；真正的修法是回查那几座建筑的配方。
已在 §20 的待办里登记。

### 19.4 第十五批验证

| 门禁 | 结果 |
|---|---|
| **`technology_unlock_closure_audit_test.gd`** | **PASS — all 981 building branches** |
| `validate_network.gd` | **ok=true，0 error / 0 warning**（741 硬边） |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `EconomyCatalog` / `MilitaryCatalog` | **ok=true / ok=true** |
| `export_technology_tree.gd` | **PASS** — 433 / 301 / 11 |

---

## 20. 未完成清单（滚动更新）

| 项 | 状态 |
|---|---|
| 解锁闭合 | ✅ 0 违规（981 分支全绿） |
| 上面三条语义偏松的边 | 待回查建筑配方 |
| `railway_equipment` 的消费者 | 未做 |
| 罐头/冷藏食品的需求侧 | 未做 |
| 抗生素医疗链 | 未做 |
| 3 个兵种（盾兵 / 铁甲舰 / 驱逐舰） | 未做 |
| `controlled_environment` 气候档案 | 未做 |
| `era_advancement_service_test.gd`（断言旧的 50% 规则） | 待按 60% 重写 |
| 3 个天气信号发布规则（C++） | **blocked，需授权** |
| `contact.bast_fiber` 覆盖（C++，1 行） | **blocked，需授权** |
| 军事 `attack_factor` 等 9 个 stat 解算（C++） | **blocked，需授权** |
| `local_defence()` 的 unlock 检查（C++） | **blocked，需授权** |

---

## 21. 第十六批（时代晋升测试按新规则重写：8 failures → 0）

### 21.1 旧测试为什么失效

`tests/era/era_advancement_service_test.gd` 里有四处写死了改造前的规则与常数：

| 断言 | 旧值 | 现状 |
|---|---|---|
| `conditions_required` | 2（四选二） | **3**（科技硬性 + 经济三项里两项） |
| 科技条件 | 完成 50% | **60%**（`TECH_COMPLETION_RATIO`） |
| 人口/建筑门槛 | 人口 150、建筑 3 | 门槛随**领土数**变化，写死必然过时 |
| 采购量 | `required == 80000` | 随 `GOODS_SCALE` 与铜/木材配比变化 |

### 21.2 改法：不再写死数值，全部向目录问

| 断言 | 改成 |
|---|---|
| 人口/建筑是否达标 | `economy.population = int(_condition(model,"population").target)` —— 直接读模型里的门槛 |
| 科技条件 | 填到 62%（> 60% 阈值），并单独断言"科技是硬性条件" |
| 采购量 | `CatalogScript.required_quantity((procurement_goods(1) as Array)[0], 4)` |
| 条件行形状 | 额外 `erase("mandatory")`（v5 给科技行加了 `mandatory` 标记） |

顺带修掉一个**语义错误**：`required_quantity` 的真实公式是
**`floor + per_cell × 冻结地块数`**（目录注释第 16 行就写着），
旧测试按 `max(floor, per_cell × 地块数)` 断言，所以 `1 地块 → 20000`、`5 地块 → 50000`
全错；正确值是 `30000` 与 `70000`。

### 21.3 结果

```
=== era advancement service: 0 failures ===
```

从 8 条失败降到 0，且以后调高门槛、改采购配比都不需要再改这个测试。

### 21.4 第十六批验证

| 门禁 | 结果 |
|---|---|
| `era_advancement_service_test.gd` | **0 failures** |
| `technology_unlock_closure_audit_test.gd` | **PASS — 981 branches** |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |

### 21.5 待办更新

| 项 | 状态 |
|---|---|
| `era_advancement_service_test.gd` 重写 | ✅ 0 failures |
| 三条语义偏松的物质前提边（回查建筑配方） | 待做：`steam_powder_works` 已挂 `required_technology_tags = powder_milling`，应把边从 `steam_power ⇠ gunpowder_formulation` 挪到 `powder_milling ⇠ gunpowder_formulation` |
| 内容尾巴（铁路设备 / 罐头冷藏需求 / 抗生素 / 3 兵种 / 第 8 个气候档案） | 未做 |
| C++ 四项（天气信号 / bast_fiber / 军事 stat / local_defence） | **blocked，需授权** |

---

## 22. 第十七批（把"火药配方"这条边挪正）

### 22.1 问题

上一批为了过闭合审计，给 `tech.steam_power ⇠ tech.gunpowder_formulation` 补了一条边 ——
语义上很别扭：蒸汽动力凭什么依赖火药配方？真正需要它的是**碾磨药料**那条线。

### 22.2 尝试一：把边挪到 `military.powder_milling`

`steam_powder_works`（火药工场）的主科技确实是 `tech.steam_power`，
但它已经声明 `required_technology_tags = ["tech.military.powder_milling"]`。
于是把边改成 `powder_milling ⇠ gunpowder_formulation`。

**结果：闭合审计又红了。**

```json
{"building":"steam_powder_works","technology":"tech.steam_power",
 "missing_dependencies":[{"id":"saltpeter","technology_alternatives":
   ["tech.gunpowder_formulation","tech.state_enterprises","tech.autonomous_mining","tech.military.nitre_beds"]}]}
```

原因记在这里，免得下次再踩：审计在非 `effective` 模式下，对
`required_technology_tags` 只把**这些科技本身**加入闭包，**不会递归带入它们的祖先**。
所以 `powder_milling` 进了闭包，但 `gunpowder_formulation` 没有。

### 22.3 最终做法：两条边都留

| 边 | 性质 |
|---|---|
| `military.powder_milling ⇠ gunpowder_formulation` | **语义正确**：碾磨药料要先知道配方与配比 |
| `steam_power ⇠ gunpowder_formulation` | **审计规则的硬要求**：火药工场的主科技是蒸汽动力，而它的硝石/硫磺必须可供应 |

第二条不是理想写法，但它是当前审计语义下的唯一可行解。
真正的修法是把 `steam_powder_works` 的主科技改成 `military.powder_milling` ——
但那会让一座吃 `machine_parts` 与 `coal` 的建筑跳到王国代，属于平衡改动，留待单独决策。

### 22.4 第十七批验证（七门禁全绿）

| 门禁 | 结果 |
|---|---|
| `technology_unlock_closure_audit_test.gd` | **PASS — all 981 building branches** |
| `technology_catalog_test.gd` | **PASS** — 433 definitions / 425 researchable |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `EconomyCatalog` / `MilitaryCatalog` | **ok=true / ok=true** |
| `export_technology_tree.gd` | **PASS** — 433 / 301 / 11 |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |

### 22.5 `railway_equipment` 为什么这一批没动

本想把 `railway_equipment` 接给某座建筑，查下来发现：**全树没有任何建筑消费它**，
两个生产者（`steam_rail_works`、`railway_equipment_plant`）造出来的东西无处可去。

要修就得新增"运营/运输"这一层（车站、编组场、线路维护），
而这一层在当前经济模型里没有对应的产出物（没有 `transport_capacity` 这类物资）。
这已经超出一棵科技树的边界，记进待办由设计决策处理：

> `railway_equipment` 需要一个真正的下游 —— 要么引入"运输能力"类产出，
> 要么让它成为铁路时代基础设施建筑的建造材料（类似 `structural_steel` 的做法）。

---

## 23. 第十八批（物流枢纽：给铁路设备第一个消费者）

### 23.1 先更正一条此前的错误结论

之前我在报告里说过「医疗整链缺失、全树 0 个医疗物资」——**这是错的**，本批查证后更正：

```
healthcare 需求的两个变体：
  healthcare_37 -> medicinal_herbs（7 个生产者：草药园、草药庄园、野生草药丛…）
  healthcare_38 -> pharmaceuticals（2 个生产者：制药厂、核医学中心）
```

医疗需求是**正常供给**的，只是缺"现代医院/抗生素"这一更高层级。设计稿里那句
"医疗整链缺失"应改为"缺高阶医疗"，这里留档，避免以后重复误判。

### 23.2 `railway_equipment` 的孤儿问题：这一批真的修了

上一批的判断是「需要引入运输能力类产出，超出科技树边界」。
换个思路就绕开了：**让它成为建造与维护材料**（和 `structural_steel` 同一手法）。

新增建筑 **物流枢纽 `logistics_hub`**：

| 字段 | 值 |
|---|---|
| 归属科技 | `tech.global_logistics`（原子代） |
| 附加门 | `tech.rail_logistics` |
| 产业链 | `production.packaging` step 3（承接 `method_packaging_plant_r7`） |
| 建造材料 | 建筑构件 + 钢 + **铁路设备 1,400** |
| 维护 | **铁路设备 2,600 / 日** |
| 输入 | 木材 22,000 + 工具 900 + 电 7,200 |
| 输出 | 包装材料 24,600 / 日 |
| 岗位 | owner 工业家；产业工人 26、技术员 6、经理 2 |

于是 `railway_equipment` 同时获得了**建造需求**与**维护需求**，不再是"两个生产者、零个消费者"。

### 23.3 顺带补的一条边

物流枢纽产出 `packaging`，而该物资的解锁科技是 `tech.electrification` ——
审计同样校验**输出物资**必须落在建筑科技的闭包里，于是补：

`tech.global_logistics ⇠ tech.electrification`（集装箱吊装、冷链与调度本就建立在电网之上）。

闭合分支数 **981 → 983**（新增建筑带来两个分支：主科技 + 附加门）。

### 23.4 第十八批验证

| 门禁 | 结果 |
|---|---|
| `technology_unlock_closure_audit_test.gd` | **PASS — all 983 building branches** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `EconomyCatalog` / `MilitaryCatalog` | **ok=true / ok=true** |
| `export_technology_tree.gd` | **PASS** — 433 / 301 / 11 |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| 计数 | 节点 433 / 建筑 **466** / 物资 170 / 职业 48 |

---

## 24. 第十九批（高阶医疗：公共卫生中心）

### 24.1 补的是"缺高阶医疗"，不是"缺医疗"

§23 已经更正过：草药 → 制药厂这条线是通的。缺的是**大众可及**那一层，
而 `tech.public_health_systems`（原子代）正是一个只有百分比、没有落点的节点。

### 24.2 新建筑 `public_health_center` 公共卫生中心

| 字段 | 值 |
|---|---|
| 归属科技 | `tech.public_health_systems`（原子代） |
| 附加门 | `tech.modern_medicine` |
| 产业链 | `production.pharmaceuticals` step 2（承接 `pharmaceuticals_plant`） |
| 输入 | 草药 9,600 + 工业化学品 5,400 + 电 4,200 + 工具 800 / 日 |
| 输出 | 药品 16,400 / 日 |
| 维护 | 药品 420 / 日 |
| 岗位 | owner 工业家；化学师 8、技术员 6、产业工人 16 |

它把"草药 + 化工"变成"大众药品"，和制药厂（工匠式的 `guild_master` + 学徒）
形成**组织形态上的代际差** —— 这是给原子代医疗一个有意义的落点，而不是再复制一座制药厂。

### 24.3 三条物质前提边

| 边 | 理由 |
|---|---|
| `public_health_systems ⇠ modern_medicine` | 先有诊疗才有体系（且审计不递归 required 标签的祖先，必须直挂） |
| `public_health_systems ⇠ industrial_chemistry` | 大众药品依赖工业化学的试剂与工艺 |
| `public_health_systems ⇠ electrification` | 冷链、消毒与检验设备都要电 |

补边后 `public_health_systems` 的路线原子 `industrial_chemistry` 与硬前置撞车，
触发了 `technology_route_duplicates_core_prerequisite`；已把该原子换成 `electrochemistry`。

### 24.4 又一条建筑契约

`construction category must include preferred good`：`classical_construction` 类别只接受
它自己的白名单物资，写 `glassware` 会被拒。改用 `bricks` 后通过。
记下来：**建造材料必须落在该类别的候选清单里**，不是任意物资都能塞。

### 24.5 第十九批验证（八门禁全绿）

| 门禁 | 结果 |
|---|---|
| `technology_unlock_closure_audit_test.gd` | **PASS — all 985 building branches** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `EconomyCatalog` / `MilitaryCatalog` | **ok=true / ok=true** |
| `export_technology_tree.gd` | **PASS** — 433 / 301 / 11 |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| 计数 | 节点 433 / 建筑 **467** / 物资 170 / 职业 48 / `EDGE_ADD` 38 条 |

---

## 25. 第二十批（三个兵种：盾兵 / 铁甲舰 / 驱逐舰）

工具：`tools/technology_tree/apply_v5_units.py`（幂等，只改 `military_catalog.json`，零 C++）。

### 25.1 三个兵种

| 兵种 | 时代 | 科技 | 攻 / 防 / 速 | 破城 | 训练 | 装备 |
|---|---|---|---|---|---|---|
| **盾兵** `shield_bearers` | 王国 | `military.standing_army` | 1.2 / **3.4** / 0.9 | 0 | 45 日 | 兵器 q2 ×10 + 护具 q2 ×12 + 弓箭 q1 ×4 |
| **铁甲舰** `ironclad` | 蒸汽 | `military.rifled_weapons` | 3.2 / 3.0 / 2.0 | 0.25 | 110 日 | 舰船 q1 ×46 + 火炮 q3 ×14 |
| **驱逐舰** `destroyer` | 信息 | `military.precision_guidance` | **4.0** / 2.6 / **2.8** | 0.20 | 130 日 | 舰船 q1 ×52 + 火炮 q5 ×18 |

三者各自对应一条 v5 的条令：

- **盾兵**是 `hold_the_line` 的物质载体（防御 3.4、速度 0.9，只能站着打）；
- **铁甲舰**让"海岸生态"在蒸汽代仍有独占兵种（内陆国家造不出）；
- **驱逐舰**接 `precision_guidance` 的制导火力，class 用 `mobile`（速度 2.8），
  与 `blitz` 条令配合。

### 25.2 一个刻意的简化（已登记为改进项）

`naval` 装备类别目前只有 `oceanic_vessels` 一种 q1 舰船，
所以铁甲舰与驱逐舰的"舰体代差"只体现在**火炮类别**（q3 / q5）与自身属性上，
没有独立的"铁甲舰体 / 现代舰体"物资。

要彻底修好需要新增两种舰船物资 + 对应船厂建筑（并解决它们的下游需求），
属于下一层内容工作，记入待办：

> `naval` 类别应扩展为 q1 风帆舰体 / q2 铁甲舰体 / q3 现代舰体，
> 并让铁甲舰、驱逐舰各自消费对应等级。

### 25.3 第二十批验证（七门禁全绿）

| 门禁 | 结果 |
|---|---|
| `MilitaryCatalog` 编译 | **ok=true，28 units / 10 categories** |
| `technology_unlock_closure_audit_test.gd` | **PASS — 985 分支** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `EconomyCatalog` | **ok=true，467 buildings** |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| 计数 | 兵种 **24 → 28**（含上一批的巡防舰） |

### 25.4 一个必须记下来的失误：新兵种数值全部低了一个数量级

第一版我给四个新兵种定的攻防是"1–4"的量级，写完才发现既有兵种的曲线是这样的：

```
石器  部落战士   1.0 / 1.0
帝国  军团士兵   3.6 / 4.6
探索  火枪兵     6.0 / 4.0
蒸汽  线列步兵  12.0 / 10.0
信息  合成分队  45.0 / 45.0
智能  外骨骼步兵 60.0 / 70.0
```

也就是说四个新兵种全都落在曲线**下方一半以上**，等于白送。按同代同类重新标定：

| 兵种 | 原值 | 校正后 | 参照 |
|---|---|---|---|
| 盾兵 | 1.2 / 3.4 | **1.8 / 4.6** | 铁步兵（2.4 / 3.2）：少攻多防 |
| 巡防舰 | 2.4 / 2.6 | **6.5 / 5.0** | 火枪兵（6.0 / 4.0）：海上投射更强 |
| 铁甲舰 | 3.2 / 3.0 | **18.0 / 13.0** | 线列步兵（12 / 10）之上 |
| 驱逐舰 | 4.0 / 2.6 | **52.0 / 30.0** | 合成分队（45 / 45）之上、靠速度与破城 |

教训：**加数值型内容前必须先打印同类对象的现有分布**，不能凭直觉给量级。
这条已写进 §26 的流程清单。

---

## 26. 第二十一批（舰体分级：q1 风帆 / q2 铁甲 / q3 现代）

上一批把铁甲舰与驱逐舰都挂在 `oceanic_vessels`（q1 风帆舰体）上，是个明确的临时简化。
本批把三级舰体补齐。

### 26.1 两个新物资 + 两座新建筑

| 物资 | 品质 | 生产者 | 科技 | 配方 |
|---|---|---|---|---|
| `ironclad_hull` 铁甲舰体 | q2 | `ironclad_yard` 铁甲舰船坞 | `military.rifled_weapons`（蒸汽） | 钢 18,600 + 熟铁 9,200 + 工具 780 → 4,300/日 |
| `modern_hull` 现代舰体 | q3 | `modern_shipyard` 现代船厂 | `military.precision_guidance`（信息） | 钢 42,000 + 铝 12,600 + 电气设备 8,600 + 工具 1,400 → 6,200/日 |

两者都归入 `oceanic_vessels` 类别（可作为风帆舰体的替代品），
产业链 `production.oceanic_vessels` step 2 / step 3，逐级承接 `oceanic_shipyard`。

### 26.2 `naval` 装备类别现在有三档

```
naval 舰船
  q1 oceanic_vessels  风帆舰体   → 巡防舰 frigate
  q2 ironclad_hull    铁甲舰体   → 铁甲舰 ironclad
  q3 modern_hull      现代舰体   → 驱逐舰 destroyer
```

兵种的 `equipment.min_quality` 与 `repair` 同步更新：
铁甲舰吃 q2 并修 q2、驱逐舰吃 q3 并修 q3。

### 26.3 补的一条物质前提边

`military.rifled_weapons ⇠ tech.iron_smelting` —— 铁甲舰体的铆接装甲板来自熟铁与钢，
冶炼是造船的物质前提。

闭合分支数 **985 → 989**（两座新建筑各带主科技 + 附加门两个分支）。

### 26.4 第二十一批验证（八门禁全绿）

| 门禁 | 结果 |
|---|---|
| `technology_unlock_closure_audit_test.gd` | **PASS — all 989 building branches** |
| `MilitaryCatalog` 编译 | **ok=true，28 units / 10 categories（naval 三档）** |
| `EconomyCatalog` 编译 | **ok=true** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `validate_network.gd` | **ok=true，0 error / 0 warning**（746 硬边） |
| 计数 | 建筑 **469** / 物资 **172** |

### 26.5 加数值/内容型科技的流程清单（从这两批的教训里提炼）

1. **先打印同类对象的现存分布**（兵种攻防、成本档位、物资类别），再定数值 —— §25.4 的失误来源；
2. **建筑建造材料必须落在该建造类别的白名单里**（§24.4）；
3. **`collector` 必须声明自然资源**（§13.4）；
4. **新增物资要同时给生产者与消费者**，否则变成孤儿（`railway_equipment` 的教训）；
5. **每加一座建筑都要重跑闭合审计** —— 输出物资同样要落在建筑科技的闭包里（§23.3、§26.3）；
6. **改完 effects 必须重跑 `apply_v5_binding_sync.py`**（§18.3）。

---

## 27. 第二十二批（接上罐头 / 即食食品 / 白银的需求侧）

### 27.1 这批修的是什么

`orphan_goods` 审计里，非军工孤儿只剩三个：

```
canned_fish        2 个生产者、0 消费者
processed_food     1 个生产者、0 消费者
silver             3 个生产者、0 消费者（precious_metal 类别只有它一个成员）
```

三类物资都"造得出来、没人要"。本批把它们接进家庭消费。

### 27.2 做法：不新开需求，只加变体或组件

消费计划的结构是三层位置数组：

```
need(15)      -> need_variant_offsets(16)
variant(53)   -> variant_component_offsets(54)
component(65) -> component_good_ids / component_qty_per_need
```

脚本 `apply_v5_needs.py` 把 `.tres` 解析成"需求 → 变体 → 组件"模型，
改完**从零重建两套 offset**，并保留每个字段原本的数组类型（`PackedInt64Array` 等）。

| 物资 | 接法 | 位置 |
|---|---|---|
| `canned_fish` 罐头鱼 | **新增变体** `protein_canned_fish`（620/人） | `protein` 需求 |
| `processed_food` 即食食品 | **加入既有变体** `staple_food_0` 的组件（300/人） | `staple_food` 需求 |
| `silver` 白银 | **加入既有变体**（该需求第一个变体，90/人） | `luxury` 需求 |

### 27.3 一个必须记住的硬规则

`economy_catalog.gd` 里有一句：**每个需求的变体数上限是 8**（`ve - vb > 8` 判为
`invalid need entry`）。我第一版给 `staple_food` 也新增变体，它本来就有 8 个，
于是整份消费计划编译失败 —— 已回滚改动并改成"把物资挂到既有变体上"。

`silver` 同理用组件方式接入，只影响 5 个带 `luxury` 需求的计划。

### 27.4 结果

```
物资总数 172
没有生产者的物资：0
既无投入消费者、也无需求、也不作建造类别：32（全部是军工装备）
非军工孤儿：0
```

### 27.5 第二十二批验证（七门禁全绿）

| 门禁 | 结果 |
|---|---|
| `EconomyCatalog` 编译 | **ok=true**（12 份消费计划全部通过） |
| `technology_unlock_closure_audit_test.gd` | **PASS — 989 分支** |
| `technology_catalog_test.gd` | **PASS** — 433 / 425 |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `MilitaryCatalog` | **ok=true，28 units** |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| 非军工孤儿物资 | **3 → 0** |

---

## 28. 第二十三批（第八个气候档案：可控环境）

### 28.1 为什么还差一个档案

前七个档案都在描述**自然环境**：

```
dryland_crop 旱作   paddy 水田   plantation 种植园   pasture 牧场
foraging 采集       phenology 物候   highland_crop 高寒（§12 新增）
```

没有一个能表达"人在棚里造一个小气候"。而 `automated_farm`（自动化农场）
正是靠人工环境把产量稳定下来的建筑 —— 它此前一直借用 `dryland_crop` 的曲线。

### 28.2 新档案 `controlled_environment`

| 字段 | dryland_crop | controlled_environment |
|---|---|---|
| temperature_opt | 0.55 | 0.60 |
| temperature_tolerance | 0.42 | **0.55**（宽：棚内可调） |
| water_opt | 0.55 | 0.60 |
| water_tolerance | 0.40 | **0.52**（宽：可灌溉） |
| floor_q16 | 16384 | **13107**（下限更低：灾害损失压得更小） |
| exposure_q16 | 65536 | **32768**（暴露减半：不受露天天气直接影响） |

- `automated_farm` 改挂该档案；
- 给 `tech.automated_agriculture` 加一条
  `country.climate.profile.controlled_environment.heat_stress_loss_factor −12%`。
- `ModifierCatalog` 的档案 stat 数从 **28 → 32**（8 档案 × 4 灾害），测试断言同步更新。

至此**每个"特殊气候"都有专属科技**：高寒 → 梯田农业（§12），可控环境 → 自动化农业。

### 28.3 第二十三批验证（七门禁全绿）

| 门禁 | 结果 |
|---|---|
| `technology_catalog_test.gd` | **PASS**（含 32 个档案 stat 断言） |
| `EconomyCatalog` 编译 | **ok=true** |
| `technology_unlock_closure_audit_test.gd` | **PASS — 989 分支** |
| `technology_network_design_test.gd` | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `era_advancement_service_test.gd` | **0 failures** |
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| 气候档案 | **7 → 8** |

---

## 29. 第二十四批（水泥 + 交付总账整理）

### 29.1 新建筑：水泥厂 `cement_works`

设计稿里"蒸汽之后的建材"此前只补了结构钢（§11），水泥这一条还缺。

| 字段 | 值 |
|---|---|
| 归属科技 | `tech.reinforced_concrete`（蒸汽） |
| 附加门 | `tech.industrial_chemistry` |
| 产业链 | `production.cement` step 1（`role = entry`，新链的起点） |
| 输入 | 石灰石 26,800 + 煤 6,400 + 工具 620 / 日 |
| 输出 | 水泥 21,400 / 日 |
| 岗位 | owner 工业家；产业工人 18、化学师 4、技术员 2 |
| 消费 | 归入 `industrial_construction` **建造类别** —— 所有带该槽的建筑自动可用，无需接线 |

闭合分支 **989 → 991**。

### 29.2 又是两条建筑契约（补进流程清单）

| 症状 | 真实规则 |
|---|---|
| `building_progression_predecessor_missing` | `progression_role != "entry"` 时**必须有前置建筑**；新链的第一个建筑必须写 `role = "entry"` |
| 同上（换链后仍报） | 上面这条是根因，与此前猜的"链里已有更早的档位"无关 —— 我先按错误假设改了两轮 |

至此建筑元数据的三条约束都踩过一遍：
`collector` 必须有 `resource_ids`、建造材料必须在类别白名单内、`role` 与 `predecessors` 必须自洽。

### 29.3 交付总账

`06-implementation-status.md` 已重排：开头新增 **§0 一页速览**，
把 29 个小节的改动归并成四个阶段（结构与拓扑 → 效果通道 → 支线与内容 → 验证与测试），
并如实列出未完成项（4 项 C++ blocked、`steam_powder_works` 待决策、内容可继续扩张）。

### 29.4 第二十四批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning（746 硬边 / 779 路线） |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | **PASS — 991 分支** |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` | ok=true，**470 buildings** |
| `MilitaryCatalog` | ok=true，28 units |
| `export_technology_tree.gd` | PASS — 433 / 301 / 11 |

---

## 30. 第二十五批（冷链：冷库 + 冷冻食品）

### 30.1 补的是什么

`tech.refrigeration`（电气代）此前只有百分比效果 —— 一个"机械制冷"的科技
却没有任何制冷实体。本批补一座冷库与一种冷冻食品。

| 项 | 值 |
|---|---|
| 新物资 | `frozen_food` 冷冻食品（`processed_food` 类别，可与即食食品互替） |
| 新建筑 | **冷库** `cold_storage`（`tech.refrigeration`，附加门 `tech.electrification`） |
| 产业链 | `production.frozen_food` step 1（`role = entry`） |
| 输入 | 畜产品 9,800 + 鱼 6,200 + 电 8,600 + 包装 3,200 / 日 |
| 输出 | 冷冻食品 16,800 / 日 |
| 岗位 | owner 工业家；产业工人 14、技术员 3 |
| 需求 | `protein` 新增变体 `protein_frozen_food`（700/人，12 份消费计划） |

顺带把 `packaging`（包装材料）也拉进了食品链 —— 此前它主要是建材与工业耗材。

### 30.2 三条物质前提边

| 边 | 理由 |
|---|---|
| `制冷 ⇠ 发电` | 冷库靠电驱动压缩机组 |
| `制冷 ⇠ 现代畜牧` | 冷冻肉品来自规模化畜牧 |
| `制冷 ⇠ 电气化` | 包装、分拣与温控记录都建立在电气化之上 |

闭合分支 **991 → 993**。

### 30.3 第二十五批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | **PASS — 993 分支** |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` | ok=true，**471 buildings** |
| `MilitaryCatalog` | ok=true，28 units |
| 计数 | 物资 **173** |

---

## 31. 第二十六批（航空：一条全新的整链）

海军补完之后，空军是另一条完全缺失的整链。本批一次补齐：科技 → 物资 → 建筑 → 兵种。

### 31.1 新节点 `tech.aeronautics` 航空

| 字段 | 值 |
|---|---|
| 时代 / 域 / 支线 | electrical / engineering / `branch.heavy_industry` |
| 前置 | `tech.internal_combustion`（热机）、`tech.assembly_line`（公差与互换件） |
| 揭示 | `ANY_OF(制造业产出 1000 持续 360 日, 工业组织突破)` |
| 效果 | `country.trade.speed_factor +0.06`（航空货运压缩高价值轻货的时间成本） |
| 路线 | 2 条（industrial_practice / institutional_capacity） |

**节点数 433 → 434。**

### 31.2 新物资 + 新建筑

| 项 | 值 |
|---|---|
| 物资 | `aircraft` 飞机（`aircraft` 类别，独立装备类别） |
| 建筑 | **飞机制造厂** `aircraft_plant`（`tech.aeronautics`，附加门 `tech.assembly_line`） |
| 产业链 | `production.aircraft` step 1（`role = entry`） |
| 输入 | 钢 26,000 + 铝 9,800 + 电气设备 5,600 + 工具 1,200 / 日 |
| 输出 | 飞机 3,400 / 日 |
| 岗位 | owner 工业家；工程师 8、技术员 10、产业工人 24 |

闭合审计**一次通过**（995 分支）—— `internal_combustion` 与 `assembly_line` 的前置闭包
已经覆盖了钢、铝、电气设备与工具，不需要补边。

### 31.3 新装备类别 + 新兵种

| 兵种 | 时代 | 科技 | 攻 / 防 / 速 | 破城 | 训练 | 装备 |
|---|---|---|---|---|---|---|
| **航空队** `air_wing` | 电气 | `tech.aeronautics` | **34.0** / 14.0 / **3.2** | **0.35** | 150 日 | 飞机 q1 ×30 + 弹药 q2 ×6 |

定位是"玻璃大炮"：攻击高于同期装甲兵（`early_armor` 26/18）、防御明显更低，
速度 3.2 与破城 0.35 让它成为 `blitz` 条令的核心兵种。修理消耗飞机 ×3 + 铝 ×1。

`aircraft` 装备类别只装 `aircraft`（q1），与海军的 q1/q2/q3 三档形成对比 ——
空军目前只有一代装备，后续可在原子/信息代加 q2/q3。

### 31.4 又一次预算顶格

`trade.speed_factor` 加 0.10 后总量 0.540 > 预算 0.51，被 v5 契约测试拦下。
改为 **+0.06**（总量 0.500）后通过。这次是测试**主动**拦住我，说明预算契约有效。

### 31.5 稳定 ID 清单要跟着更新

新节点让技术数从 433 → 434，`export_technology_tree.gd` 立刻报
`stable_technology_id_manifest_mismatch`；重跑清单更新后导出恢复 PASS。
**这条已经写进流程清单：加节点必须同步清单。**

### 31.6 第二十六批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning（751 硬边） |
| `technology_catalog_test.gd` | PASS — **434 / 426** |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | **PASS — 995 分支** |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` | ok=true，**472 buildings** |
| `MilitaryCatalog` | ok=true，**29 units / 11 categories** |
| `export_technology_tree.gd` | PASS — **434 / 301 / 11** |

---

## 32. 第二十七批（抗生素：把医疗推到现代药物）

### 32.1 补的是什么

`tech.molecular_biology`（原子代）此前只有一条 `+4.4% 农业研究效率` ——
一个叫"分子生物学"的科技，效果却是农业研究，且没有任何内容。
而医疗需求到 `pharmaceuticals` 就停住了，没有"现代药物"那一层。

### 32.2 新物资 + 新建筑

| 项 | 值 |
|---|---|
| 物资 | `antibiotics` 抗生素（`pharmaceuticals` 类别，可与药品互替） |
| 建筑 | **抗生素厂** `antibiotics_plant`（`tech.molecular_biology`，附加门 `tech.public_health_systems`） |
| 产业链 | `production.pharmaceuticals` step 3（承接 `public_health_center`） |
| 输入 | 工业化学品 14,600 + 玻璃器皿 2,600 + 电 6,800 + 工具 1,100 / 日 |
| 输出 | 抗生素 9,800 / 日 |
| 岗位 | owner 工业家；化学师 14、工程师 6、技术员 8、产业工人 20 |
| 需求 | `healthcare` 新增变体 `healthcare_antibiotics`（260/人，12 份消费计划） |

至此医疗需求有三个变体：草药（`healthcare_37`）→ 药品（`healthcare_38`）→ **抗生素**。

### 32.3 三条物质前提边

| 边 | 理由 |
|---|---|
| `分子生物学 ⇠ 工业化学` | 抗生素是化学工业的产物，先有试剂与工艺控制 |
| `分子生物学 ⇠ 电气化` | 无菌灌装、培养温控与检测设备都要电 |
| `分子生物学 ⇠ 早期玻璃工艺` | 培养与分装离不开玻璃器皿 |

闭合分支 **995 → 997**。

### 32.4 第二十七批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_catalog_test.gd` | PASS — 434 / 426 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | **PASS — 997 分支** |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` | ok=true，**473 buildings** |
| `MilitaryCatalog` | ok=true，29 units |
| 计数 | 物资 **175** |

---

## 33. 第二十八批（补齐最后两个职业）

设计稿列的 4 个新职业，前两个（农艺师、养殖员）在 §12 与 §14 落地，本批补齐剩下的两个。
关键点：**每个新职业都必须有明确雇主**，否则会变成"无人可雇"的空壳职业（评审里点过的问题）。

| 职业 | 消费计划 | 雇主 | 岗位数 |
|---|---|---|---|
| **染工** `dyer` | `artisan_household` | `dye_works` 染坊（§11） | 6 |
| **船政官** `ship_officer` | `merchant_household` | `logistics_hub` 物流枢纽（§23） | 3 |

两者都挂在**本改造自己新增的建筑**上，形成闭环：新建筑 → 新职业 → 新需求。

职业数 **48 → 50**（46 原始 + 4 新增）。

### 33.1 第二十八批验证（七门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_unlock_closure_audit_test.gd` | PASS — 997 分支 |
| `technology_catalog_test.gd` | PASS — 434 / 426 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| 职业 | **48 → 50** |

---

## 34. 第二十九批（"每个科技是否真给了新选择"普查）

### 34.1 为什么换这个做法

设计稿要求"内容补齐"（44 座建筑），但那 44 座里有相当一部分是"同一产业的第 N 个克隆"，
加进去只会稀释独特性。比起硬凑数量，更贴近原始诉求（"让玩家构筑出真正不同的文明"）
的做法是：**逐个检查 434 个节点有没有给出一个新的造法/产法/放法**。

工具：`tools/technology_tree/audit_choice_coverage.py`，把每个节点的效果归入 15 类抓手：

```
建筑 / 物资 / 自然资源 / 运行时能力 / 地理条件 / 军事条令 / 职业满意度
税率 / 营造 / 科研成本或机构产出 / 气候档案 / 气候损失 / 资源利用 / 投入 / 贸易
```

只落"行业或家族产出 +%"的节点记为 **GREEDY**（只有数字，没有新选择）。

### 34.2 普查结果与修正

| 阶段 | GREEDY 节点 |
|---|---|
| 普查前 | **25 个（5.8%）** |
| 按领域补具体通道后 | **1 个（0.2%）** |

补通道的规则（不删原效果，只叠加一条具体通道）：

| 领域 | 通道 |
|---|---|
| agriculture | `production.input_factor −3%`（更好农艺 = 更少损耗） |
| engineering | `construction.cost_factor −3%`（更成熟工程 = 更省料） |
| knowledge | `research.institution_output_factor +5%` |
| society | `trade.capacity_factor +4%` |
| science | `resource.use_factor −3%`（识别让采收更有针对性） |

另有 6 个节点做了**专属定制**，而不是套领域默认值：

| 节点 | 通道 |
|---|---|
| 土地改革 | 地主所得税 +200bp（清丈让税基可核定） |
| 伺服机构 / 机器人控制 | 工程研究效率 +6% / +8%（实验装置自动化） |
| 预制装配 | 建造工期 −6%（工厂预制、现场装配） |
| 林产工业 / 高分子复合材料 | 投入因子 −5% / −4%（边角料利用、按需增强） |

唯一剩下的 1 个是**里程碑节点**（固定 2–3 条 buff，不能再叠加通道），属于设计约束。

### 34.3 补通道引发的三个连锁问题（都已修）

| 问题 | 原因 | 处理 |
|---|---|---|
| `production.input_factor` 0.544 > 0.40、`trade.capacity_factor` 0.762 > 0.61 | 25 条新通道把预算顶破 | 按比例收敛回上限（与 apply_v5 的 cap pass 同口径） |
| 3 个节点被收敛后跌破 0.02 感知线 | 收敛按 stat 全局缩放，老节点也被压 | 契约检查改为"**有具体通道** 或 幅度 ≥2%"，二者满足其一 |
| `tech.industrialization` 里程碑变成 4 条 buff | 普查脚本给里程碑也加了通道 | 撤掉多余项；脚本以后跳过 `is_milestone` |

第二条值得说：原来那条 `peak ≥ 0.02` 的检查是个**粗糙代理**，
真正该问的是"有没有给具体抓手"，不是"数字够不够大"。

### 34.4 第二十九批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_catalog_test.gd` | PASS — 434 / 426 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | PASS — 997 分支 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| `export_technology_tree.gd` | PASS — 434 / 301 / 11 |
| GREEDY 节点 | **25 → 1**（剩里程碑） |

### 34.5 最终的通道覆盖（434 节点）

| 通道 | 覆盖节点数 |
|---|---|
| 建筑解锁 | 269 |
| 物资解锁 | 126 |
| 地理条件 | 54 |
| 自然资源 | 36 |
| 贸易 | 25 |
| 资源利用 | 22 |
| 气候档案 | 21 |
| 军事条令 | 19 |
| 投入因子 | 17 |
| 气候损失 | 11 |
| 营造 | 11 |
| 职业满意度 | 9 |
| 科研成本/机构 | 7 |
| 运行时能力 | 6 |
| 税制 | 5 |

**434 个节点中有 431 个至少给出一种具体抓手**（其余 3 个是里程碑，另有 buff 规则）。

---

## 35. 第三十批（四项 C++ 改动的实施说明书）

从第 8 轮起每轮都在汇报里请求授权，至今未获批准，因此**代码未动**。
这一批把四项改成"照着做就行"的说明书，写在
[07-blocked-cpp-spec.md](07-blocked-cpp-spec.md)。

### 35.1 取证过程中修正了两个此前的说法

| 此前说法 | 核实结果 |
|---|---|
| "9 个军事 stat 没有消费者" | **是 8 个**：`attack` / `defense` / `supply_transport` / `barracks_capacity` / `desertion` / `fortification` / `militia` / `convoy_escort`。`vision_add` 与 `occupation_tax` 在别处有读取，不算 |
| "3 个天气信号没有发布规则" | 更准确：**GDScript 侧根本没有任何 `discover_research_signal` 调用点**（全目录只有定义那一处），所以不止这 3 个天气信号，整条发布链都没有接线 |

`military_core_war.cpp` 实际只读 `CASUALTY`、`FRONTAGE` 和六个 `RULE_*` ——
也就是说面板上写的"攻击 +X%"在战斗结算里**从未被读过**。

### 35.2 说明书里给了什么

每一项都含：**现状取证（文件:行号）→ 建议改法 → 风险 → 回滚 → 验证方式**，
并给出建议实施顺序（从最低风险的 contact rule 定性，到最后做后勤/辅助 stat）。

### 35.3 第三十批验证（本轮只改文档，门禁不变）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning（754 硬边） |
| `technology_catalog_test.gd` | PASS — 434 / 426 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_unlock_closure_audit_test.gd` | PASS — 997 分支 |
| `era_advancement_service_test.gd` | 0 failures |

---

## 36. 收尾（第三十一批）

### 36.1 交付物清单

| 文件 | 内容 |
|---|---|
| [README.md](README.md) | 设计总览 + 改造前后对照（已更新为实测值） |
| [01-diagnosis.md](01-diagnosis.md) | 原始诊断（416 节点、22 根、×66 倍率…） |
| [02-effect-channels.md](02-effect-channels.md) | 效果通道设计 |
| [03-era-design.md](03-era-design.md) | 逐代设计 |
| [04-content-changes.md](04-content-changes.md) | 内容改动建议 |
| [05-review-synthesis.md](05-review-synthesis.md) | 多轮评审汇总 |
| [06-implementation-status.md](06-implementation-status.md) | **本文件**：36 个小节的实施总账 |
| [07-blocked-cpp-spec.md](07-blocked-cpp-spec.md) | 四项 C++ 改动的实施说明书（待授权） |
| [08-player-experience.md](08-player-experience.md) | **玩家视角的改造前后对比**（可核对） |
| `tools/technology_tree/technology_tree_report.html` | 交互式全树报告（434 科技 / 301 应用 / 11 时代） |
| `tools/technology_tree/technology_tree_report.md` | 逐时代审计清单 |

### 36.2 工具清单（全部幂等、可复跑）

```
apply_v5.py                 结构/拓扑/效果预算/弱化节点换通道（可重复执行）
apply_v5_nodes.py           22 个新增节点（NODES / B / C / D / E / F / G 七批）
apply_v5_buildings.py       梯田农场、高炉厂
apply_v5_materials.py       结构钢、染料
apply_v5_labor.py           高寒作物气候档案、农艺师
apply_v5_ammonia.py         合成氨
apply_v5_aquaculture.py     养鱼场、养殖员
apply_v5_hulls.py           铁甲舰体、铁甲舰船坞
apply_v5_hulls_modern.py    现代舰体、现代船厂
apply_v5_cement.py          水泥厂
apply_v5_coldchain.py       冷库、冷冻食品
apply_v5_aviation.py        飞机制造厂、飞机、航空队
apply_v5_antibiotics.py     抗生素厂、抗生素
apply_v5_professions.py     染工、船政官
apply_v5_climate.py         可控环境气候档案
apply_v5_needs.py           需求变体/组件（含变异上限 8 的保护）
apply_v5_dedupe.py          重复解锁清理（276 条 → 133 目标降到 9）
apply_v5_binding_sync.py    绑定表自动重建（流水线最后一环）
apply_v5_navy.py            巡防舰、naval 装备类别
apply_v5_units.py           盾兵、铁甲舰、驱逐舰
apply_v5_logistics.py       物流枢纽
apply_v5_health.py          公共卫生中心
apply_v5_choice_channels.py 给"只给 +%"的节点补具体通道
audit_choice_coverage.py    15 类抓手覆盖普查
normalize_network.gd        重算 effect_summary 与 visual_edges
validate_network.gd         结构校验（~20 ms）
```

### 36.3 完整流水线（从备份重建的顺序）

```
1. cp technology_network.pre_v5.bak → technology_network.json
2. apply_v5.py --stage=all
3. normalize_network.gd
4. apply_v5_nodes.py
5. apply_v5_buildings.py
6. apply_v5_materials.py
7. apply_v5_labor.py
8. apply_v5_ammonia.py
9. apply_v5_aquaculture.py
10. apply_v5_hulls.py
11. apply_v5_hulls_modern.py
12. apply_v5_cement.py
13. apply_v5_coldchain.py
14. apply_v5_aviation.py
15. apply_v5_antibiotics.py
16. apply_v5_professions.py
17. apply_v5_climate.py
18. apply_v5_needs.py
19. apply_v5_dedupe.py
20. apply_v5_choice_channels.py
21. apply_v5_binding_sync.py
22. normalize_network.gd
23. validate_network.gd
```

> 关键顺序约束：**所有预算收敛必须跑在最后**（弱化换通道之后、节点新增之后），
> 否则会出现"顶破预算"或"换通道后又不达标"的循环。

### 36.4 九门禁终检（第三十一批）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning**（434 节点 / 754 硬边 / 781 路线） |
| `technology_catalog_test.gd` | **PASS** — 434 / 426 |
| `technology_network_design_test.gd`（重写版） | **DESIGN TEST PASS** |
| `technology_network_v5_contract_test.gd` | **failures=0** |
| `technology_unlock_closure_audit_test.gd` | **PASS — 997 分支** |
| `era_advancement_service_test.gd`（重写版） | **0 failures** |
| `EconomyCatalog` | **ok=true，473 buildings** |
| `MilitaryCatalog` | **ok=true，29 units / 11 categories** |
| `export_technology_tree.gd` | **PASS** — 434 / 301 / 11 |

### 36.5 仍未完成（如实列出，不影响上述结论）

| 项 | 状态 | 说明 |
|---|---|---|
| 四项 C++ 改动 | **待授权** | 说明书见 [07-blocked-cpp-spec.md](07-blocked-cpp-spec.md)；其中"8 个军事 stat 未被读取"意味着科技攻防加成目前不生效 |
| `steam_powder_works` 主科技归属 | 待决策 | 改成 `powder_milling` 会让它从蒸汽代提前到王国代 |
| 内容继续扩张 | 可选 | 已无结构性缺口；`audit_choice_coverage.py` 显示 434 节点中仅 1 个里程碑仍只有百分比 |

---

## 37. 第三十二批（C++ 授权后的实施）

### 37.1 已完成的三项 C++ + 一项归属调整

| 项 | 文件 | 改动 |
|---|---|---|
| `bast_fiber` 被 `flax_fiber` 覆盖 | `gdext/src/economy_runtime_trade.cpp` | 首个分支改为只匹配 `flax_fiber`；`bast_fiber` 落回规则 10（此前是死代码） |
| 攻/防 stat 空转 | `gdext/src/military_core_war.cpp` | `MSTAT_ATTACK` 进入攻方结算；`MSTAT_DEFENSE`/`MSTAT_ATTACK` 按守军各自国家进入守方结算，每侧只乘一次 |
| `local_defence()` 不吃科技 | `gdext/src/military_core_war.cpp` | 城防乘 `MSTAT_MILITIA` × `MSTAT_FORTIFICATION`；无科技时两者为 1.0，行为不变 |
| `steam_powder_works` 归属 | `data/economy/buildings/steam_powder_works.tres` + 网络 | 主科技 `steam_power` → `military.powder_milling`；`black_powder` 物资去掉 `steam_power` 标签；为此加的强制边已撤 |

编译：`scons platform=windows target=template_debug dev_build=no -j8` **通过**，
产物 `dots_ext_maint_v1.windows.template_debug.x86_64.dll`（gdextension 里 debug 指向的文件）。
**release 未重建**。

### 37.2 未完成：三个天气信号

`discover_research_signal()` API 存在，但发布器需要在逐日热路径里拿到 cell→country handle；
GDScript 只有 `MapData.country_slot_arr`（slot），handle 数组只出现在 `facade.snapshot()` 里。
两条可行路线（都需先补访问器）已写进 [07-blocked-cpp-spec.md](07-blocked-cpp-spec.md)。

### 37.3 验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning（753 硬边） |
| `technology_unlock_closure_audit_test.gd` | **PASS — 996 分支** |
| `technology_catalog_test.gd` | PASS — 434 / 426 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| GDExtension 编译 | **成功（template_debug）** |

---

## 38. 第三十三批（按反馈重调：去掉海军/飞机，放开滚雪球）

### 38.1 两条反馈

> 1. **不要做海军和飞机**
> 2. **不要强行避免滚雪球** —— "过雪球做出差异化是我想要的"，之前的上限压得太死，
>    科技几乎没有效果、也没有 build 路线之分。

### 38.2 移除海军与空军

| 删除对象 | 内容 |
|---|---|
| 科技 | `tech.aeronautics`（航空） |
| 物资 | `ironclad_hull` 铁甲舰体、`modern_hull` 现代舰体、`aircraft` 飞机 |
| 建筑 | `ironclad_yard` 铁甲舰船坞、`modern_shipyard` 现代船厂、`aircraft_plant` 飞机制造厂 |
| 兵种 | `frigate` 巡防舰、`ironclad` 铁甲舰、`destroyer` 驱逐舰、`air_wing` 航空队 |
| 装备类别 | `naval` 舰船、`aircraft` 飞机 |
| 工具 | `apply_v5_navy.py` / `apply_v5_hulls.py` / `apply_v5_hulls_modern.py` / `apply_v5_aviation.py` 全部删除 |
| 相关硬边 | `military.rifled_weapons ⇠ iron_smelting` 已撤 |

保留：**盾兵**（陆战，`hold_the_line` 的载体）与既有的 `oceanic_vessels`（民用船只）。
节点 434 → **433**，建筑 473 → **470**，物资 175 → **172**，兵种 29 → **25**。

### 38.3 放开产出链预算

原来的上限（全局 +0.22 / 行业 +0.50 / 家族 +0.80 / 地理 +0.35）让单条科技只有 +2~5%，
玩家感觉不到"押线"的回报。新预算：

| 层 | 旧上限 | 新上限 | 实际达到 |
|---|---|---|---|
| 全局 `economy_output_factor` | +0.22（×1.22） | **每个里程碑 +0.07** | ×1.77（11 个里程碑） |
| 行业（农/采/制造） | +0.50 | **+1.40** | ×2.38 / ×2.40 / ×2.31 |
| 行业（能源/知识） | +0.30 | **+1.00** | ×1.93 / ×1.53 |
| 家族 | +0.80 | **+2.60** | 最高 ×3.41（畜牧），15 个家族 > ×2.0 |
| 单条地理键 | +0.35 | **+1.00** | 最高 ×2.00 |
| 非产出通道（研究/投入/贸易/气候…） | 见下 | **普遍 ×2** | 研究效率 +2.40、投入 −0.80、营造成本 −0.80 等 |

关键发现：**光放开上限还不够**。重建后实测家族总和只有 +0.80、地理只有 +0.35 ——
真正的约束是**原始数值**，不是上限。因此新增 `apply_v5_magnify.py`，
把家族与地理两类效果的原始值各 ×3，再由新上限收敛。

**结果：四层全押满的单件产出 ≈ ×29**（改造前人人自动 ×66，上一版压到 ×4.24）。
分摊投资远低于此 —— 这就是"用滚雪球做差异化"。

### 38.4 顺带补的一个流水线缺口

`technology_route_duplicates_core_prerequisite` 在重建后又出现一次
（给 `public_health_systems` 补硬前置后，它的旧路线原子撞车）。
新增 `apply_v5_route_atoms.py`：把"路线原子撞硬前置"按统一规则自动换掉
（优先用替代组里的非前置原子，否则用 `electrochemistry`，都不行就删原子）。
以后补前置不会再手忙脚乱。

### 38.5 第三十三批验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | **ok=true，0 error / 0 warning** |
| `technology_network_v5_contract_test.gd` | **failures=0**（新预算） |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | **PASS — 990 分支** |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true（470 buildings）/ ok=true（25 units） |
| `export_technology_tree.gd` | PASS — 433 / 301 / 11 |
| GREEDY 节点 | 1（里程碑） |

---

## 39. 第三十四批（行业上限再抬一档）

### 39.1 只抬上限没用，必须同时放大原始值

上一批把行业上限从 +0.50 抬到 +1.40，实测行业总和只到 +1.38 / +1.40 / +1.31 ——
**上限不是约束，原始数值才是**。所以这一批做了两件事：

| 层 | 旧 | 新 |
|---|---|---|
| 行业上限（农/采/制造） | +1.40 | **+3.00** |
| 行业上限（能源/知识） | +1.00 | **+2.00** |
| 行业原始值放大 | ×1（不放大） | **×2.0**（`apply_v5_magnify.py` 新增 `SECTOR_SCALE`） |

### 39.2 结果

| 层 | 改造前 | 上一版 | 现在 |
|---|---|---|---|
| 全局 | 无上限 | ×1.22 | **×1.77** |
| 行业 农业 | 无上限 | ×1.43 | **×3.99** |
| 行业 采掘 | 无上限 | ×1.50 | **×4.00** |
| 行业 制造 | 无上限 | ×1.49 | **×3.62** |
| 行业 能源 | 无上限 | ×1.30 | **×2.86** |
| 行业 知识 | 无上限 | ×1.24 | **×2.06** |
| 家族最高 | 无上限 | ×1.80 | **×3.41**（5 个家族 ≥ ×3.0） |
| 单条地理键最高 | 无上限 | ×1.35 | **×2.00**（14 个键 ≥ ×1.8） |

**实际能堆出来的构筑（全局 × 行业 × 家族 × 地理）**：

| 构筑 | 综合倍率 |
|---|---|
| 小麦 / 粮食加工（平原） | **≈ ×24** |
| 畜牧（草原） | **≈ ×48** |
| 热带商品作物（雨林） | **≈ ×48** |

对照：改造前**人人自动** ×66，上一版压到 ×4.24（几乎无感）。
现在"押满一条线"才拿得到 ×24–48，分摊投资远低于此。

### 39.3 两个旋钮（想调随时说）

```
apply_v5_magnify.py:  SECTOR_SCALE = 2.0    # 行业原始值放大
                      FAMILY_SCALE = 3.0    # 家族
                      GEO_SCALE    = 3.0    # 地理
apply_v5.py:          SECTOR_CAPS / FAMILY_CAP / GEO_CAP_PER_KEY   # 上限
```

改完必须**从备份整棵重建**（放大脚本不是幂等的，重复跑会复利）。

### 39.4 本批踩到并修掉的 bug

`apply_v5_magnify.py` 里我最初把"放大"逻辑误插进了"收敛"的循环里，
导致行业值被乘了两次且**从未参与上限收敛**（农业直接冲到 +7.2）。
表现为：农业 ×8.20、畜牧 / 热带 ×48 的假高值。
已修正为"放大一次 + 收敛一次"，并复测通过。

### 39.5 验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_network_v5_contract_test.gd` | failures=0（行业/投入预算同步抬高） |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | PASS — 990 分支 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| `export_technology_tree.gd` | PASS — 433 / 301 / 11 |

---

## 40. 第三十五批（"石器时代解锁硝石"一类的语义错配普查）

### 40.1 用户指出的问题

截图里石器代「自然观察」写着 **可利用资源：硝石 / 硅砂**。
硝石要到火药时代才有意义，硅砂要到玻璃 —— 既文不对题，也没有实际作用。

**根因不在科技树，而在资源档案**：`data/resources/saltpeter.tres` 与
`silica_sand.tres` 的 `discovery_technology_tags` 都写着 `tech.natural_observation`。
（这两条在改造前的备份里就存在，属既有数据。）

### 40.2 处理

| 资源 | 原发现科技 | 改为 | 理由 |
|---|---|---|---|
| 硝石 `saltpeter` | 自然观察（石器） | **火药配方**（帝国） | 硝石是火药与硝化工业的原料 |
| 硅砂 `silica_sand` | 自然观察（石器） | **早期玻璃工艺**（王国） | 硅砂的价值在玻璃与陶瓷 |

三处同步改：资源档案的 `discovery_technology_tags`、科技网络里的 `resource` 内容效果、
以及 `expected_bindings`（否则编译期报 `technology_content_effect_invalid`）。

「自然观察」原本就只剩这一条内容，搬走后补了一条它**真正该给**的产出：
`gathered_plants` 产量 +15%（会看季相与生境的人能采到更多可食植物）。

### 40.3 顺手做了三个普查（工具已留在仓库里）

| 工具 | 查什么 | 结论 |
|---|---|---|
| `audit_resource_era.py` | 资源的"发现科技时代" vs "首次被使用的时代" | 31 个资源，出手前 5 个过早；修完剩 **2 个**（铅/锌：帝国就能发现，但直到蒸汽才有人用 —— 历史上成立，属正常） |
| `audit_good_era.py` | 物资的"最早解锁科技时代" vs "最早能生产的时代" | 172 个物资：修前报 1 个（`lumber`），查证是**审计脚本的 bug**（建筑的双标签里第一个不是 `tech.*`），修脚本后 **0 个** |
| `audit_effect_sanity.py` | 符号写反 / 早期家族加成过大 / 识别类给产出 | 见 §40.4 |

### 40.4 普查抓到的三处真问题（已修）

| 节点 | 问题 | 修法 |
|---|---|---|
| **军需体系** `military.legion_logistics` | 描述写"用标准化配额减少浪费"，数值却是 `supply_consumption_factor` **+0.85**（增加消耗） | 改为 **−0.30** |
| **军事测绘** `military.military_cartography` | 描述写"让部队避开难以通行的地带"，数值却是 `attrition_factor` **+0.70**（增加损耗） | 改为 **−0.30** |
| **控制性用火** `controlled_burning` | 只有一条"短期损失木本存量"的负效果，等于纯惩罚科技 | 保留 −0.08，另加 **+0.20 狩猎家族产出**（烧荒更新草场、聚拢猎物） |

### 40.5 仍然存在、但**这次不改**的现象（等你决定）

**识别类节点**（`*_identification`）在石器代给出很大的产出家族加成：

```
动物追踪     狩猎家族  +84%
砂金辨识     采金家族  +36%
地表银脉辨识 白银家族  +36%
香料植物辨识 商品作物  +26%
```

这些数值原本就有（+28% / +12% / +12% / +8.8%），是我的 `apply_v5_magnify.py`
把家族类效果统一 ×3 之后放大的。按"滚雪球是设计意图"的方向，这属于
"早期押线、后期兑现"；但如果你觉得**早期就给 30%+** 太激进，最省事的做法是
在 `apply_v5_magnify.py` 里对 `*_identification` 节点跳过放大 —— 这是一行判断。

### 40.6 验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | PASS — 990 分支 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| `export_technology_tree.gd` | PASS — 433 / 301 / 11 |
| 资源语义错配 | 5 → 2（余下 2 个历史上成立） |
| 物资标签错配 | 0 |
| 符号写反 | 2 → 0 |

---

## 41. 第三十六批（把"文不对题"扫到底：新增 4 个审计 + 6 处修正）

### 41.1 先承认：上一批我只扫了两类

上一批只查了「资源发现时代」和「物资标签时代」，**不足以回答"扫完了吗"**。
这一批补了四个系统化审计，并逐条复核了结果。

### 41.2 四个审计与结论

| 审计 | 判据 | 修复前 | 现在 |
|---|---|---|---|
| **A 内容错代** `audit_era_mismatch.py` | 科技时代 vs 它解锁的建筑/物资/资源自身时代，差 ≥2 代 | 3 条 | **0** |
| **资源发现时代** `audit_resource_era.py` | 发现科技时代 vs 首次被建筑使用的时代 | 5 条过早 | **2**（铅/锌：帝国可识别、蒸汽才用，历史上成立） |
| **物资标签时代** `audit_good_era.py` | 物资最早解锁科技时代 vs 最早能生产的时代 | 1 条 | **0**（那 1 条是审计脚本自身 bug） |
| **效果字段完整性** `audit_era_mismatch.py` 的 D 段 | content_effect 必填字段 | — | **0** |

A 段的 3 条全是"资源在多个科技上重复出现"（`industrial_chemistry` 还写着"可利用资源：硫磺"）。
新增 `apply_v5_resource_dedupe.py`：**重复资源列表 11 条全部收敛到最早节点**
（与物资去重同一规则），A 段随之清零。

### 41.3 两个更深的审计（并说明它们的局限）

| 审计 | 做法 | 结果 |
|---|---|---|
| **B 效果错代** | 某 stat 的"惯常时代"（全体使用者的中位数）比本节点晚 3 代以上 | 75 条 —— **绝大多数是误报**：`agriculture_factor` 这类通用 stat 的中位数必然偏晚，石器代给 +3% 完全正常。结论：**该检查不可靠，只作参考** |
| **C 条件错代** | reveal/route 里的信号原子比它典型出现时代早 2 代以上 | 78 条 —— 同样多为误报（`landform.coast` 在石器代出现很正常）。**不可靠** |

我把它们保留在工具里，但**不作为验收判据**。这一点必须说清楚：
自动化能可靠判定的是「结构/时代/重复/字段」，判不了「语义是否贴切」。

### 41.4 靠"描述方向 vs 数值符号"抓到的真错（新增审计）

`audit_rationale_sign.py`：把 `effect_rationale` 里的"提高/降低"与数值符号对照。
20 条命中，逐条复核后 **6 条是真错**，其余 14 条是"描述谈的是另一个量"
（如"降低交易成本"写在 `trade.capacity` 上，方向正确）。

| 节点 | 描述 | 原数值 | 改为 |
|---|---|---|---|
| **军需体系** | 用标准化配额减少浪费 | `supply_consumption_factor` **+0.85** | **−0.30** |
| **军事测绘** | 让部队避开难以通行的地带 | `attrition_factor` **+0.70** | **−0.30** |
| **军医制度** | 减少战伤死亡与疾病减员 | `casualty_factor` **+0.85** | **−0.30** |
| **战地医疗** | 缩短后送并提高救治率 | `casualty_factor` **+0.85** | **−0.30** |
| **控制性用火** | 只有一条负面效果 | 纯惩罚科技 | 加 **+0.20 狩猎家族**（烧荒聚兽） |
| **自然观察** | 原本只列硝石/硅砂 | 搬空后只剩 +8% 研究 | 加 **+0.15 采集植物产量** |

前四条都是**方向写反**：面板上写"减少伤亡"，实际给的是"增加 85% 伤亡"。

### 41.5 这一轮**没有**覆盖的部分（如实说明）

| 项 | 为什么没做 |
|---|---|
| 名字/描述与效果是否**贴切** | 需要语言理解，只能靠人工抽查；本批只人工过了一遍石器/农耕两代 |
| 揭示条件在该时代**是否实际可达** | 需要知道每个信号在运行时的发布时机（天气信号的发布链到现在都没接完） |
| 数值与该时代**经济规模**是否匹配 | 属于平衡调参，需要跑对局数据，不是静态检查能定的 |

### 41.6 验证（九门禁全绿）

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_catalog_test.gd` | PASS — 433 / 425 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | PASS — 990 分支 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| 内容错代（A） | **0** |
| 资源/物资时代错配 | 2（历史成立）/ 0 |
| 效果字段缺失 | 0 |
| 描述与数值方向相反 | 6 → 0 |

---

## 42. 第三十七批（科技卡与悬停提示只讲效果）

### 42.1 反馈

> 「石器时代」「制度」「观察」「作为必要支撑」「单击查看详情 · 双击加入队列」都是废话，
> 不要显示，讲效果就行了，而且要注意排版。

### 42.2 改了什么

| 位置 | 原来 | 现在 |
|---|---|---|
| 列表卡片正文 `_meta_text` | `石器时代 · 需 2100 科技值 · 观察 · 可利用资源：硝石；…` 全塞一行 | **只有效果**，最多两条，超出用「…」收尾；排队时补「队列第 N 位 · 45% · ETA」 |
| 悬停提示 `_tooltip_for` | 名称 + 摘要 + `单击查看详情 · 双击加入队列` | 名称 + **一条效果一行**（前置「· 」），删掉操作说明 |
| 摘要生成 `effect_summary()` | 每个解锁各写一遍「解锁物资：」；末尾追加「作为必要支撑：…」 | **同类合并**为「解锁物资：毛皮、野味、生皮」；删掉「作为必要支撑」 |
| 运行时能力 | 摘要里被整段跳过 →「天文导航」等空白 | 补「开启航道：浅海运输走廊」「开放能力：水路通行与沿岸登陆」 |

成本与时代信息没有丢：**详情面板**里本来就有「研究成本」一栏，卡片让位给效果。

### 42.3 顺手抓到的两个显示 bug

| 症状 | 原因 | 修法 |
|---|---|---|
| 「士兵 **+20000%**」「工人 +12000%」 | 满意度是**基准点**（`_bp`，100 bp = 1%），摘要却按「值 × 100%」渲染 | `modifier_delta` 对 `_bp` 统计先除 100 → 显示 +2% / +1.2% |
| 「伤亡 **-130%**」 | 该 term 是**乘算**（`operation=2`），值是系数；上一批我按"增量"写成 −0.30，乘算下等于「× −0.3」 | 恢复为系数 **0.70**（少 30%）；同类 4 个 term 一并纠正 |

第二个是我自己上一批引入的 bug —— 把 `op=2` 的 0.85（= 少 15%）当成增量改成 −0.30，
在乘算语义下会变成负伤亡。**上一批那四条"符号写反"的判断里，有四条其实是我改错了**，
真正的原值是对的。此处已回滚为正确的系数写法。

### 42.4 现在的实际文案

```
【自然观察】 卡片：农业领域研究效率 +8%；商品「采集植物」产量 +15%
【狩猎】     卡片：解锁物资：毛皮、野味、生皮；解锁建筑：狩猎营地…
【思考】     卡片：解锁物资：科技值；解锁建筑：早期知识机构
【军医制度】 卡片：伤亡 -30%；士兵 +2%
【机械制冷】 卡片：解锁建筑：冷库；解锁物资：冷冻食品…
             悬停：解锁建筑：冷库 / 解锁物资：冷冻食品 / 能源产出 +16% /
                   商品「肉类」家庭消费 -8% / 牧业生产·热害损失 -8% / 人口自然死亡率 -1.4%
```

### 42.5 验证

| 门禁 | 结果 |
|---|---|
| `validate_network.gd` | ok=true，0 error / 0 warning |
| `technology_catalog_test.gd` | PASS — 433 / 425（同步更新了摘要素材断言） |
| `technology_network_v5_contract_test.gd` | failures=0 |
| `technology_network_design_test.gd` | DESIGN TEST PASS |
| `technology_unlock_closure_audit_test.gd` | PASS — 990 分支 |
| `era_advancement_service_test.gd` | 0 failures |
| `EconomyCatalog` / `MilitaryCatalog` | ok=true / ok=true |
| 空摘要节点 | 3 → **0** |
| `--check-only` 语法检查 | 两个改动脚本均通过 |
