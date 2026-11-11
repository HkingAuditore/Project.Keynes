# 科技树 v5 设计方案 · 第二部分：效果通道框架

> 本部分定义"一个科技允许被写成什么"。第三部分（逐时代方案）完全遵守本部分的规则。

---

## 0. 前提变了：研究是强制的，所以身份必须在"部署"层产生

第一部分的定论：**每代必须完成 80% 的非里程碑科技**（`era_advancement_catalog.gd:22`）。
全局只有约 **73 个节点**可以放弃，其中 24 个是"只给全局 +4~8%"的无差别节点 —— 真正的构筑决策点约 **50 个 / 416（12%）**。

这个前提推翻了 4X 科技树设计的常规假设：

| 常规假设 | 本项目的实际 |
|---|---|
| 科技树是"选哪条路" | 科技树是"必须走完的那条路" |
| 差异化来自"我研究了 A 而你没有" | 差异化只能来自"我们都研究了 A，但我用得起、你没用得起" |
| 支线 = 选项 | 支线 = 路段 |
| 科技效果 = 解锁能力 | 科技效果 = **提供互斥的部署选项** |

**因此，本方案的核心命题是：**

> **科技树不负责让玩家"成为不同的文明"，它负责让玩家"有可能成为不同的文明"。**
> 真正的分叉发生在部署层：你能在哪块地上建、用什么配方跑、雇谁干活、付不付得起。

这就把"效果设计"从"给加成"改成了"给选择"。四个部署通道：

| 通道 | 玩家要做的决定 | 为什么它能制造差异 |
|---|---|---|
| **G — 地理** | 我把产业放在哪种地形/地貌/气候上 | 两个玩家的地图不同，同一科技的价值就不同 |
| **C — 构成** | 我的工厂吃什么、吐什么 | 同一产物有 2–3 套配方，取决于你手上有什么 |
| **L — 岗位** | 我用谁组织生产 | 种群结构、阶层、工资、税基随之不同 |
| **P — 财政** | 我收多少税、补贴谁、造得多快 | 同样的产业规模，财政结构不同 |

加上 **U — 解锁**（提供新的可部署对象）与 **S — 制度**（长期社会形态），构成六个通道。

**最关键的一条改写**：

> **U 通道必须是"给出替代方案"，而不是"再多一个更强的建筑"。**
> 如果一个科技解锁的建筑与既有建筑功能同构、只是数值更高（现状 114 座 `method_*` 克隆，中位产出 ×7.78，最高 ×522），那它提供的不是选择，是替换。玩家会直接换掉旧的，文明形态不变。

---

## 1. 效果通道定义与落点

| 代号 | 通道 | 数据落点（全部已存在） |
|---|---|---|
| **U** | Unlock 解锁 | `BuildingProfile.technology_tags` / `GoodProfile.technology_tags` / `ResourceProfile.discovery_technology_tags` / 职业引用 |
| **C** | Composition 构成 | `input_good_ids` / `input_candidate_good_ids` / `input_required_q16` / `input_min_quality_levels` / `output_good_ids` / `output_cost_shares_q16` / `resource_ids` + `resource_access_modes` |
| **L** | Labor 岗位 | `owner_profession_id` / `employee_profession_ids` / `employee_slots_per_building` / `employee_wage_policy_ids` |
| **G** | Geography 地理 | `country.output.terrain.<t>.<s>_factor`（150 个）/ `country.output.landform.<l>.<s>_factor`（75 个）/ `country.climate.profile.<p>.<h>_loss_factor`（24 个）/ `country.resource.<r>.use_factor` / `BuildingProfile.condition_*` 放置条件（**支持 NOT，opcode 4**） |
| **P** | Price 财政 | `country.tax.*`（5 族）/ `country.production.input_factor` / `country.construction.cost_factor` / `country.construction.time_factor` / `country.household.consumption_factor` / `country.trade.*` |
| **S** | Society 制度 | `country.ideology.*`（15 个）/ `economy.profession.<p>.satisfaction_bp` / `economy.profession.<p>.tax_tolerance_factor` / `country.population.death_factor` / `country.research.*` |
| **M** | Military 军事 | `data/military/military_catalog.json` 的 `units[]` / `equipment_categories[]` / `state_buildings[]`；`country.military.rule.*`（6 个战术条令） |

**现状用量 vs 可用量**：

| 通道 | 可用 | 现状使用 | 使用率 |
|---|---|---|---|
| G（地形/地貌×行业） | 225 | **4 term / 3 节点** | 1.3% |
| G（气候档案×灾害） | 24 | 38 term | — |
| P（税制） | 5 族 | **0** | 0% |
| P（营造成本/工期） | 2 | **0** | 0% |
| P（投入成本） | 1 | 10 | — |
| S（意识形态） | 15 | **0** | 0% |
| S（职业满意度/税负容忍） | 46×2 | **0** | 0% |
| S（科研节奏 cost/institution） | 2 | **0** | 0% |
| M（战术条令） | 6 | **0** | 0% |
| 家族产出百分比 | 每家族 1 | **118** | 已饱和 |

---

## 2. 六条硬性编写规则

### 规则 1 · 部署选项规则（"质变规则"）

> 一个科技的效果列表里，必须至少有 **1 项部署选项**：一个 U（新增可建/可产/可雇，**且与既有对象不同构**）、一个 C（改变配方或资源获取方式）、或一个 G（改变"在哪里建"的价值）。
> 纯 P / S 的节点只允许三种情况，且必须标 `quantitative_justified`：① 里程碑；② 主干底座；③ 灾害适应。

**为什么**：在 80% 强制下，玩家一定会拿到这个科技。如果它的内容是"+8% 产出"，那它只是给整棵树加了一次乘数；如果它的内容是"多一种建厂方式"，那它给了玩家一个新决定。

现状 **137 个节点（33%）** 违反这条规则。

### 规则 2 · 单通道预算（"加法预算规则"）

> 全树（11 代全部研究完 —— 由于 80% 强制，这基本等于"实际全部研究完"）在同一 stat 上的累计值不得超过下表预算。

| stat | 全树累计上限 | 单节点建议值 | 说明 |
|---|---|---|---|
| `country.economy_output_factor` | **+0.15** | +0.02 ~ +0.03 | **只允许 6 个时代里程碑使用**（6×0.025 = 0.15） |
| `country.output.<行业>_factor` | **+0.60** | +0.04 ~ +0.08 | 每行业最多 6–8 个节点 |
| `country.output.family.<家族>_factor` | **+0.90**（招牌）/ **+0.40**（通用） | +0.06 ~ +0.10 | 招牌家族 = 该支线的核心产线 |
| `country.output.good.<物资>_factor` | **+0.60** | +0.05 ~ +0.10 | 单物资 |
| `country.output.terrain/landform.<x>.<s>_factor` | **+0.35 / 每格** | +0.10 ~ +0.25 | **地理条件触发，允许强** |
| `country.climate.profile.<p>.<h>_loss_factor` | **−0.60 / 每档案每灾害** | −0.08 ~ −0.15 | 灾害损失 |
| `country.climate.<hazard>_loss_factor`（通用） | **−0.30** | −0.05 | 弱于档案专属 |
| `country.production.input_factor` | **−0.25** | −0.05 | 投入成本 |
| `country.construction.cost_factor` / `time_factor` | **−0.25 / −0.25** | −0.05 | 建造成本/工期 |
| `country.trade.capacity_factor` / `speed_factor` | **+0.45 / +0.35** | +0.06 | 贸易 |
| `country.resource.<r>.use_factor` | **−0.30 / 每资源** | −0.09 | 资源节约 |
| `country.research.<域>_efficiency` | **+0.45 / 每域** | +0.10 | 科研加速 |
| `country.research.cost_factor` | **−0.30** | −0.10 | 科研省钱（**≠ 加速**） |
| `country.research.institution_output_factor` | **+0.40** | +0.15 | 科研设施产能 |
| `country.population.death_factor` | **−0.45** | −0.05 | 现状 −1.25，已撞顶 187% |
| `country.tax.<族>.<x>.rate_bp` | **±1200 bp（±12%）** | ±200 ~ ±400 bp | 税率（见下方注） |
| `country.ideology.point_gain_factor` 等 | **+0.30** | +0.10 | 意识形态 |
| `country.ideology.reroll_cost_factor` 等 | **−0.30** | −0.10 | 意识形态 |
| `country.military.attack_factor` / `defense_factor` | **+0.25 / +0.25** | +0.05 | 泛用攻防（**先修 consumer**，见诊断 6.3） |
| `country.military.rule.*` | **≤ 0.35**（Q16） | 0.08 ~ 0.15 | 战术条令 |

> **已验证的 consumer**：`country.construction.cost_factor` → `economy_runtime_building_construction.cpp:324, 507` 与 `building_investment.cpp:1203`；
> `country.research.institution_output_factor` → `economy_runtime_country_epoch_capture.cpp:757`；
> `country.ideology.point_gain_factor` → `native_simulation_host_ideology.cpp:762`、`runtime_ideology_pod.cpp:1323`。
> **未完全验证**：`country.tax.*.rate_bp` 走的是 `country_runtime.cpp` 的 `_country_income_tax_overrides`（**override 表**），
> 因此它可能是"绝对覆盖税率"而非"相对偏移"。落地前必须先确认语义；若为覆盖值，建议改为**按时代给出绝对税率**而不是 ±bp。
> 上述三族通道本身的可用性已确认，缺的只是数值口径。

**终局倍率复核**：

```
终局倍率 ≈ (1+全局) × (1+行业) × (1+招牌家族) × (1+地理)
        ≤ 1.15 × 1.60 × 1.90 × 1.35 ≈ 4.7
```

现状是 `3.90 × 4.18 × 3.25 × 1.25 ≈ 51`。目标 **×3 ~ ×4.7**。
减下来的收益必须搬到 U / C / L / G / P / S 这些改变玩法的通道上，**不是简单砍掉**。

### 规则 3 · 唯一主通道（"不许三层叠乘"）

> 同一科技不得同时给「全局产出」+「行业产出」+「家族产出」三层百分比。一个科技只选**一层**百分比，其余必须是部署通道。

| 科技性质 | 主通道 | 允许的辅通道 |
|---|---|---|
| 新产业 / 新建筑 / 新物资 | **U**（且必须提供异构选项） | 最多 1 个窄层级百分比 |
| 新生产方式（同产物、不同投入或岗位） | **C + L** | 最多 1 个窄层级百分比 |
| 地理适应（梯田/绿洲/水田/极地/海岸） | **G** | 可叠 `BuildingProfile.condition_*` 放置条件 |
| 制度 / 组织 / 法律 | **S + P** | 不得给产出百分比 |
| 物流 / 贸易 / 金融 | **P** | 不得给产出百分比 |
| 军事工业 | **U**（兵种 + 装备）+ **C** | ≤ 1 个 `military.*` 泛用值 |
| 军事学说 | **M-条令** | ≤ 1 个泛用值 |
| 灾害适应 | **G**（档案专属） | 通用损失 ≤ 预算 1/3 |

### 规则 4 · 地理优先（"位置必须能被科技改写"）

> 每条产业支线在至少 **2 个时代** 必须提供地理条件型收益。

这是"科技与地理气候强相关"的唯一硬保证。**而且它的重要性被 80% 强制放大了**：既然人人都会研究同一条支线，那么唯一的差异就是"这条支线在你的土地上值多少"。

可用的地形/地貌（`modifier_terrain_ids` / `modifier_landform_ids`，枚举小写）：

```
terrain (30): ocean coast plain grassland forest hill mountain desert tundra snow swamp jungle
              savanna taiga steppe shrubland mangrove glacier lake reef sea_ice kelp delta oasis
              salt_flat badlands cold_desert chaparral moor floodplain mesa
landform (15): deep_ocean ocean coast lake plain lowland hill mountain peak delta badlands
               salt_flat volcano plateau rift_valley canyon
sector (5): agriculture extractive manufacturing energy knowledge
```

键已生成（150 + 75），consumer 已就位（`economy_runtime_country_epoch_capture.cpp:878–883`），全部可用。

### 规则 5 · 部署互斥（"选择必须在运营层，不能在研究层"）

既然 80% 强制，**研究层互斥没有意义**（玩家反正都要研究）。互斥必须落在**运营层**：

| 手段 | 机制 | 性质 | 运行时 |
|---|---|---|---|
| **T1 资源竞争** | 两条路线的建筑消耗同一个 `resource_ids`（`resource_interaction_modes = capacity`） | 同一片地只能养一种 | 已有 |
| **T2 岗位竞争** | 两条路线抢同一职业（`landlord` vs `cooperative_member`） | 人口池有限 | 已有 |
| **T3 地理互斥** | `BuildingProfile.condition_*` 用 **NOT**（opcode 4）+ terrain/landform 谓词 | 地块互斥 | 已有 |
| **T4 投入竞争** | 两条路线吃同一种中间品（`fertilizer` / `electricity` / `steel` / `computers`） | 中间品有限 | 已有 |
| **T5 造价压力** | 高档建筑吃更多建材/更多天 | 资本有限 | 已有 |
| **T6 科技级硬互斥** | 建筑放置条件判定"某科技已完成/NOT 已完成" | 研究层互斥 | **`new_runtime`，本方案不采用** |

**建议的 8 组部署互斥对**（详见第三部分）：

| 互斥对 | 竞争物 | 表现为 |
|---|---|---|
| 庄园制 vs 合作社制 | `arable_land` + `landlord`/`cooperative_member` | 谁拥有土地 |
| 大农场机械化 vs 家庭集约园艺 | `arable_land` + 岗位数 | 人均产出 vs 单位面积 |
| 种植园单一经济 vs 混合农业 | `plantation_land` vs `arable_land` | 出口导向 vs 内需 |
| 水田集权 vs 旱作自治 | `paddy_land` + `corvee_worker` | 治水国家 vs 自耕农 |
| 燃煤重工 vs 水电/电气化 | `coal` vs 河流区位 | 能源路径 |
| 远洋商船队 vs 近海渔业 | `coast` 容量 + `merchant` | 海洋用途 |
| 国家企业 vs 平台市场协调 | `manager` + `computers` | 谁来协调 |
| 集约畜牧 vs 草原游牧 | `pasture` 容量 + `pastoralist` | 定居 vs 移动 |

### 规则 6 · 效果强度与容量匹配（"别让强制变成惩罚"）

> 因为人人都必须研究，**每一条效果的绝对值都会被全体验**。所以单节点数值应偏保守，靠**数量与结构**取胜，而不是靠叠乘。

具体约束：见规则 2 的表。另外：

- 单节点单 stat 不得超过该 stat 预算的 **1/3**（防止一个科技包打天下）。
- 单节点 `modifier_terms` 不得超过 **4 条**（校验器上限 6，留 2 条余量）。
- 不得出现**净负面**节点。现状 `tech.controlled_burning` 花 3,400 点买永久 −8% 木材再生（唯一净负面）。

---

## 3. 成本三档制（用途变了）

在 80% 强制下，成本不再决定"要不要点"，而决定**"先点哪个"**。
所以三档制的作用是：**让每代的推进顺序成为一次决策**，并让"贵但质变"的东西占据前期资源。

| 档位 | 系数 | 语义 | 玩家感受 |
|---|---|---|---|
| **minor 小** | 0.55 U | 改善已有的事 | 顺手点掉 |
| **major 中** | 1.00 U | 打开一段产线 | 计划内支出 |
| **breakthrough 大** | 1.80 U | 改变文明形态 | **要攒钱、要排序** |

分档后每代总预算不变（第三部分给出逐代数值）。分配结果：

| 时代 | minor | major | breakthrough | 合计（保持现状） |
|---|---|---|---|---|
| stone | 25 | 20 | 11 | 172,800 |
| agrarian | 23 | 18 | 10 | 409,000 |
| kingdom | 26 | 20 | 11 | 1,104,000 |
| empire | 19 | 15 | 9 | 1,902,200 |
| exploration | 16 | 12 | 7 | 3,635,300 |
| enlightenment | 14 | 11 | 6 | 7,557,400 |
| steam | 14 | 12 | 7 | 17,376,700 |
| electrical | 14 | 10 | 6 | 34,924,200 |
| atomic | 14 | 10 | 6 | 76,528,400 |
| information | 12 | 9 | 5 | 152,775,500 |
| intelligent | 11 | 8 | 5 | 303,999,900 |

**配套规则**：每代 `milestone_candidate_ids` 中 ≥40% 必须是 breakthrough 档，且至少含 1 个 minor —— 让"进代前的最后一步"永远是一次真正的取舍。

---

## 4. 揭示与路线设计规范（重大修正）

### 4.1 三类字段的真实作用（已核验运行时）

| 字段 | 真实作用 | 允许内容 |
|---|---|---|
| `reveal_condition` | **仅对 22 个无前置根节点是硬门**；其余节点一旦有父节点完成就自动发现（`country_runtime.cpp:7567–7574`）。作用是"提前亮牌"与根节点门槛 | 全部信号类别 |
| `hard_prerequisite_ids` | **硬门 ①**（知识） | 只放核心知识，≤4 条 |
| `research_routes` | **硬门 ②**（实践），315 节点强制 | **支持 `SIGNAL_PRESENT` / `SIGNAL_COUNT`**（`technology_catalog.gd:901–914`）→ 可以把地理/接触/实践信号放进 route，**不需要新运行时** |
| `milestone_candidate_ids` | 只控制"目标时代里程碑节点何时可研究" | — |

### 4.2 新的分工：把"地域差异"搬进 route

> **这是本方案实现"科技与地理强相关"的核心手法。**

现状 route 全是 `ALL_OF(某科技, development.<本行业指标>)` —— 它用"你发展了多少"代替了"你在哪儿"。
新规范：**每条 route 必须是三选一，且三条 route 分属三类**：

| route_type | 条件形状 | 谁走得通 |
|---|---|---|
| `professional_knowledge` | `ALL_OF(相关科技, development.<本行业规模>)` | 本行业文明（正宗路径） |
| `institutional_capacity` | `ALL_OF(治理科技, development.settlement.* 或 population.*)` | 任何有城的文明（通用逃生） |
| `geographic_evidence` ← **新增类型** | `ALL_OF(相邻科技, SIGNAL_PRESENT(<landform/resource/bio/weather/contact>))` | 有那个地理/物种/经历的文明（地域身份） |
| `practice_breakthrough` ← **新增类型** | `ALL_OF(相邻科技, SIGNAL_PRESENT(breakthrough.<x>))` | 真做过这件事的文明（实践身份） |

三条 route 的 OR 保证**没有文明会被永久锁死**，同时让"地域/实践"成为**最便宜的路径**。
例（`tech.terrace_farming` 梯田农业）：

```
route.professional_knowledge  = ALL_OF(tech.grain_threshing,     development.employment.agriculture.10_90d)
route.geographic_evidence     = ALL_OF(tech.composite_tools,     SIGNAL_PRESENT(landform.plateau))
route.practice_breakthrough   = ALL_OF(tech.wild_tuber_collection, SIGNAL_PRESENT(breakthrough.terrace_maintenance))
```

一个高原文明走第二/三条，成本几乎为零；一个平原矿业文明走第一条，要先堆农业就业 —— **这就是"地理优势"该有的样子**：不是让高原文明多得 40%，而是让高原文明**少绕一大圈**。

### 4.3 揭示多样性配额（每代）

| 配额 | 要求 |
|---|---|
| 生态配额 | 每代 ≥25% 的有信号节点，其信号必须含 `landform.*` / `weather.*` / `bio.*` / `contact.*` 之一 |
| 实践配额 | 全树 ≥60 个节点使用 `breakthrough.*`（现状 **0**） |
| 接触配额 | 每代 ≥1 个节点用 `contact.*`，保证孤岛文明有补足路径 |
| 无锁死配额 | 任何节点的 route 中，必须至少 1 条**不依赖本行业**指标 |
| 信号复用禁止 | 同一信号原子不得同时出现在 `reveal_condition` 与 `research_routes`（现状 2 处） |

### 4.4 空 `reveal_condition` 的处理原则

- **11 个里程碑**：保持为空（它们是时代闸门，加条件会死锁）。
- **8 个辨识根**：必须有信号（这是**唯一**真正的地理硬门，要谨慎设计）。
- **其余 86 个**：允许留空，但**建议改为实践/传播条件**（把"发现"变成"做出"）。第三部分给出逐 ID 建议。

---

## 5. 内容侧配套规则

### 5.1 建筑

| 规则 | 内容 | 现状违规 |
|---|---|---|
| **B1 单主科技** | 每座建筑只被 1 个 `technology_tags` 主科技解锁；多条件用 `required_technology_tags` | 133 个重复目标 |
| **B2 附加门不超前** | `required_technology_tags` 的时代必须 ≥ 主科技，且最多超前 2 代 | 有超前 3 代的 |
| **B3 升级链每代一级** | 同一 `upgrade_family_id` 的两个 tier 不同代解锁 | 6 处 1/2 或 1/3 同代 |
| **B4 异构而非克隆** | 新建高层级建筑必须至少有 1 项与基底不同（输入、岗位、资源、放置条件）。纯数值克隆不允许 | 114 座 `method_*`，中位 ×7.78 |
| **B5 建材要换代** | 每 2 代至少新增 1 种建材 | **蒸汽代之后 4 代 0 新建材** |

### 5.2 物资

| 规则 | 内容 | 现状 |
|---|---|---|
| **G1 唯一解锁** | 每种物资只被 1 个科技 `unlock` | 133 个重复目标 |
| **G2 四件套** | ①≥1 生产者 ②≥1 消费者 ③所属链 ④解锁科技 | 静态已 OK |
| **G3 时序可达** | 建筑解锁时，其全部必需输入必须已经可产（否则是时序死锁） | **11 处死锁** |
| **G4 后期必须有新物质** | 启蒙/信息/智能每代新增物资 ≥10 | 现状 6 / 6 / 4 |
| **G5 维修需求** | 高价值资本品要有 `maintenance_good_ids` | 仅 4/459 |

### 5.3 职业

| 规则 | 内容 | 现状 |
|---|---|---|
| **P1 阶层阶梯** | 每条产业支线 ≥2 个阶层节点 | — |
| **P2 新职业必须有岗位** | 新职业至少被 1 座建筑引用 | 3 个职业 0 引用 |
| **P3 制度职业成对** | 互斥对两侧用不同职业 | 缺 `cooperative_member` 归属 |
| **P4 后期要有新阶层** | 后 5 代每代 ≥2 个新职业 | 现状各 1–2 个 |

---

## 6. 军事专属通道

`gdext/src/military_core_war.cpp:300–352` 已实现 6 个战术条令内核，**当前零科技使用**：

| 条令 stat | 触发条件 | 效果 | 建议语义 |
|---|---|---|---|
| `rule.mutual_support` | 2 格内有友军（≤3 支） | 每支友军给防御 | 密集队形 / 方阵 |
| `rule.last_stand` | 断补给时 | 攻防加成且不自动脱离 | 死守 / 焦土 |
| `rule.blitz` | 交战前 5 日且速度 ≥2.0 | 攻击加成 | 闪击 |
| `rule.hold_the_line` | 防御且姿态 HOLD 且被攻 | 防御加成 | 坚守 |
| `rule.encirclement` | 攻击且目标 ≥4 邻为我方 | 攻击加成 | 合围 |
| `rule.home_ground` | 本国领土作战 | 攻防加成 | 卫国 |

**军事规则**：

| 规则 | 内容 |
|---|---|
| **M1 每代 ≥1 条条令** | 军事学说节点必须给 1 个 `military.rule.*` |
| **M2 兵种是 U 通道** | 军事科技解锁兵种（`units[].tech`），`new_content` |
| **M3 泛用攻防 ≤ 预算** | `attack_factor` ≤ +0.25、`defense_factor` ≤ +0.25（现状 attack +0.64） |
| **M4 禁止数值事故** | 单节点 `supply_transport_factor` ≤ +0.30（现状有 +2.00 = ×3） |
| **M5 军事-产业耦合** | 兵种装备必须本国可产；舰船绑 `coast`；骑兵绑 `pasture`；空军绑 `aluminum`+`engines` |
| **M6 军事身份也是部署选择** | 兵种靠装备与地形区分，而不是靠 +攻防百分比 |

---

## 7. 改造后每代通道预期

| 时代 | U | C | L | G | P | S | M 条令 | 纯百分比 |
|---|---|---|---|---|---|---|---|---|
| stone | 34 | 4 | 2 | 6 | 1 | 2 | 1 | ≤8 |
| agrarian | 38 | 6 | 3 | 10 | 2 | 3 | 2 | ≤8 |
| kingdom | 40 | 8 | 4 | 14 | 3 | 4 | 3 | ≤8 |
| empire | 28 | 8 | 4 | 12 | 4 | 4 | 3 | ≤6 |
| exploration | 22 | 7 | 3 | 8 | 5 | 3 | 3 | ≤5 |
| enlightenment | 20 | 8 | 4 | 7 | 5 | 5 | 2 | ≤4 |
| steam | 26 | 10 | 5 | 9 | 6 | 5 | 3 | ≤4 |
| electrical | 24 | 9 | 5 | 9 | 6 | 6 | 3 | ≤4 |
| atomic | 22 | 10 | 5 | 10 | 7 | 7 | 3 | ≤3 |
| information | 22 | 9 | 5 | 10 | 8 | 8 | 3 | ≤3 |
| intelligent | 21 | 9 | 5 | 9 | 8 | 8 | 3 | ≤3 |

**目标**：纯百分比节点从 **137 / 416（33%）** 降到 **≤60 / 416（14%）**，其中至少一半是地理条件型。
