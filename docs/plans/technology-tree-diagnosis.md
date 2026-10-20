# 科技树深度诊断与优化方案

> 诊断基准：`Project/project-keynes/data/technology/technology_network.json`（schema 4.0，369 节点 / 11 时代 / 4 主干 / 28 分支族）
> 交叉验证：`data/resources/`（31 个 ResourceProfile）、`data/goods/`（134 个 GoodProfile）、`data/economy/buildings/`（400 个 BuildingProfile）、`gdext/src/economy_runtime_catalog.cpp`
> 参考方法论：[polytech-tree](https://github.com/secwind7/polytech-tree)（人类科技树 3D 可视化，其数据策展规范见下文）

---

## TL;DR

你的六个直觉全部有数据实锤，且根因高度集中：

| 症状 | 根因 | 量级 |
|---|---|---|
| 前后逻辑不明显 | `hard_prerequisite_ids` 里混入了大量"应用关联"而非"核心知识"，跨 ≥3 时代的长跳前置 **67 条**（最长跨 9 个时代） | 67 条边 |
| 名字-效果关联弱 | 19 个"研究机构"型科技效果同质；`method_r8/r10` 配方建筑命名机械复制 | 19+90 节点 |
| 解锁还没发现的东西 | `content_effects` 把建筑的**全生命周期**（含未来时代才能配套的 `required_technology_tags`）都列进效果，农耕时代科技的效果列表里出现工业时代建筑 | **200 条链** |
| 支线不充分 | 28 个分支族中 **20 个有断代**，6 个中途死亡；主干 `food_storage` 也断代 4 个时代；后期每时代仅 1-3 个农业节点 | 20/28 族 |
| 重复啰嗦 | `精准农业`/`自动化农业` 各 21 条效果里 **10-11 条是重复解锁石器时代就已解锁的物资**；106 个实体被多科技重复解锁 | 106 实体 |
| 结构混乱 | 同时代前置边（232）多于跨时代边；`visual_edges` 1312 条里 alternative 边 635 条超过 hard 边 526 条；探索时代成本下限 3000 低于帝国时代下限 42000 | 连线密度 7.1/节点 |

**核心修复方向**：把"核心知识 / 应用关联 / 配方阶梯"三种关系从同一个 `hard_prerequisite_ids` + `content_effects` 字段里拆开——这正是 polytech-tree 用「prereqs ≤ 4 + related 严格限量」避免的"连线糊成一片"问题。

---

## 一、六大症状逐项诊断

### 1.1 前后逻辑不明显 —— 前置边的三重污染

**数据**：全部 516 条 hard 前置边的时代跨度分布：

```
同时代 232 | 跨1代 177 | 跨2代 50 | 跨3代 29 | 跨4代 13 | 跨5代 10 | 跨6代 6 | 跨7代 5 | 跨8代 3 | 跨9代 1
```

典型病案（跨 ≥6 时代的长跳）：

| 科技 | 前置 | 跨度 | 问题 |
|---|---|---|---|
| 自主物流 | 织布 | **9 个时代** | 织物自动化与"织布"没有不可替代的知识传递关系 |
| 机器学习 | 太阳蒸发制盐 | 8 个时代 | 晒盐→ML 之间隔着整个化学与计算谱系 |
| 高地精准农业 | 高地块茎农业 | 8 个时代 | 跨越了轮作、化肥、机械化整条线 |
| 工业农学 | 早期玻璃烧制 / 牧业 / 雨养玉米 | 各 7 个时代 | 把"观察方法"混入了"生产知识" |
| 先进冶金 | 铜矿井开采 | 6 个时代 | 远超"核心原理"语义 |

**根因**：runtime 契约规定 `hard_prerequisite_ids` 只放"不可替代的核心知识"，但这些边实际承担了三种角色：
1. 核心知识传递（合法）：`炼铁 ← 铁矿辨识`
2. **方法学关联（放错位置）**：`工业农学 ← 早期玻璃烧制`——玻璃烧制提供的是"实验方法"，这属于 `research_routes[]` 的 `professional_knowledge` 路线，不该做硬前置
3. **生产原料关联（放错位置）**：`先进冶金 ← 铜矿井开采`——这是产业链上下游，属于 `application_target_ids` 应用边

同时还有 21 个**非起始节点零前置**（如 `渔舟`、`铁矿辨识`、`露头煤辨识`）。辨识类靠 reveal 信号揭示可以成立，但其中 4 个是**主干/里程碑节点**（`定居知识`、`农耕社会`、`王国体系`、`帝国网络`）——里程碑零前置等于"时代入口没有知识积累要求"，削弱了路径依赖感。

另有 4 条 `branch_successor_ids` 与实际前置反向不一致（学术社团→科学分类等）。

### 1.2 名字-效果关联弱 —— 同质化与机械命名

- **19 个"研究机构"科技全部以 `good:technology_points` 收尾**：口述传统、物候观察实践、洪水历法实践、潮汐与航向记忆、记事制度、学术机构、特许大学、方法：牧群路线议事帐、学术社团、地产测绘、公共教育、国家实验室、软件工程、地理信息系统、水文遥感、机器学习、算法治理……每个时代一个"产出科技点的建筑"。模式本身合理（每个时代的科研基础设施），但**效果呈现完全同质**，玩家看到的是"又一个产科技点的"。
- **"算法治理"解锁 `technology_points` + `smart_water_network`（智能水网）**——名字是治理理念，效果里混进了水网建筑，语义跨度大。
- **`method_r8/r10` 配方建筑群**：精准橡胶种植园、智能冶铝厂、智能化电池厂、智能化电动机厂、智能化不锈钢厂……"精准/智能/自动化 + 旧建筑名"的机械拼接，polytech-tree 把这类称为"长尾补充"，而这里它们占满了信息/智能两个时代的解锁主体。

### 1.3 解锁还没发现的东西 —— 效果列表的全生命周期泄漏（最影响体验）

**这是数据交叉验证发现的最大问题。** 建筑有 `technology_tags`（解锁门）与 `required_technology_tags`（附加门）双重科技条件。后者常包含**辨识类或地区限定科技**，而科技树把"含此建筑"的 `content_effects` 全部挂在解锁门科技上，**不检查附加门何时能满足**。

实测 **200 条**这样的链路，最典型：

| 解锁科技 | 效果列表中的建筑 | 建筑还需 | 玩家视角 |
|---|---|---|---|
| 皮革鞣制（农耕 era1） | 皮革制品工厂 / 智能皮革制品工厂 | 远洋航海（**探索 era4**） | 农耕时代就看到"智能皮革工厂"，但 3 个时代内根本造不了 |
| 早期玻璃烧制（era1） | 玻璃器皿工厂 / 智能玻璃器皿工厂 | 远洋航海（era4） | 同上 |
| 货币（王国 era2） | 珠宝厂 | 雨养玉米田（era1） | 货币与玉米种植无语义关联，纯原料依赖 |
| 城市卫生（era2） | 制皂工坊 / 工业制皂厂 | 雨养玉米田（era1） | 同上 |
| 精准农业（信息 era9） | 精准橡胶种植园 | 橡胶加工 + 数字计算 | 温带国家从未接触橡胶，效果却展示了热带种植园 |

**区分**：这不违反雾中战争契约（科技完成后其效果属于已知知识），但违反信息组织常识——**效果列表应该只展示"当前可达成"的部分**。配合 reveal 侧的发现：

**reveal 信号在中后期全面退化为经济指标**：369 节点的 reveal 信号前缀分布为 `resource.* 19 / bio.* 2 / development.* 198`，其余 150 个为空。**时代 ≥6 的 100 个有 reveal 的科技 100% 使用 `development.*`**（就业人数、建筑数、贸易量阈值）——生物、资源、地貌、天气、接触信号在中后期科技树上完全失效。"发现感"（我先见过这个东西，才能研究它）在后期只剩"经济发展到数值就弹科技"。

另有 2 处违反契约的信号复用：`淡水岸捕`、`潮间带采集` 的 reveal 与 route 复用同一信号原子（`resource.freshwater_fish` / `resource.marine_fish`）。

### 1.4 支线不充分 —— 断代矩阵

28 个分支族的（行=族，列=时代 0-10，`.`=缺席）：

```
backbone.food_storage            542121....1   内部空洞 6,7,8,9
backbone.institutions_exchange   33221211231   连续 ✓
backbone.knowledge_computation   3.3212211..   空洞 1
backbone.tools_machinery         1111.22.1..   空洞 4,7
branch.commerce_finance          1.2.4....1.   空洞 1,3,5,6,7,8
branch.computation_control       .......2176   （新起线，正常）
branch.construction_materials    741...1....   空洞 3,4,5 → 死于 6
branch.electric_intelligent_energy .......63.1 空洞 9
branch.forest_biomass            3111..1....   空洞 4,5 → 死于 6
branch.heavy_industry            .165334.2.2   空洞 7,9
branch.land_institutions         .23312.....   死于 5
branch.maize_horticulture        45.....112.   空洞 2,3,4,5,6（断 5 个时代！）
branch.maritime_logistics        31114.1.111   空洞 5,7
branch.natural_history           2.1.34...22   空洞 1,3,6,7,8
branch.rice_irrigation           3511.1...11   空洞 4,6,7,8
branch.textile_fibers            5511..1.1..   空洞 4,5,7
branch.tropical_commodities      85..3......   空洞 2,3 → 死于 4
branch.tuber_highland            54.1.......   空洞 2 → 死于 3
branch.water_wind                2213.1.....   空洞 4 → 死于 5
branch.wheat_rainfed             4711.1211..   空洞 4
（其余 7 族基本连续）
```

**四个致命点**：
1. **主干也会断**：`food_storage`（食物储藏主干）在蒸汽-信息时代（6-9）空白 4 个时代，智能时代突然复活 1 个节点。罐头、冷冻、食品工业、物流保鲜整个谱系缺失。
2. **断 5 个时代的玉米线**：`maize_horticulture` 石器 4 节点 + 农耕 5 节点后，王国到蒸汽（2-6）全空，信息/智能时代（9,10）突然复活。选择玉米路线的玩家中间 5 个时代无事可做。
3. **整族死亡**：热带商品（死于探索）、块茎高原（死于帝国）、土地制度（死于启蒙）、水利风能（死于启蒙）、建材（死于蒸汽）、森林生物质（死于蒸汽）——玩家选了这些路线，后期只能转线，之前的投入变成沉没成本。
4. **后期时代整体偏薄**：石器 73 / 农耕 64 节点 vs 后期每时代 22-26 节点，而里程碑候选从 8 个涨到 18 个、required 从 4 涨到 7——**后期节点少但候选占比高**（信息时代 24 节点 17 候选），自由度反而更低。农业 domain 从王国时代起骤降至每时代 1-4 个节点，但农业恰恰是后期配方建筑最密集的行业。

另有 21 个完全叶子节点（无后继、非候选、非里程碑、非应用源）：**畜力牵引**（era1，这么重要的科技是叶子！）、梯田农业、天文导航、工资契约、集体农业、数字市场、计算生物学、自主林业经营等。

### 1.5 重复啰嗦 —— 三层重复叠加

1. **物资重复解锁**：106 个实体被多科技解锁。最严重的两个：
   - `精准农业` 21 条 content_effects 里 **11 条是 good 重复**（玉米/小麦/水稻/土豆/蔬菜/香料/橡胶/棉/麻/药草/谷物——全部在石器-农耕时代就解锁过），真正的新内容只有 `precision_farm` + 9 个 `method_r8` 建筑。
   - `自动化农业` 同样 11 条 good 重复 + 1 建筑 + 9 个 `method_r10`。
   - 如果运行时语义是"任一科技解锁即 access"（catalog 编译侧确认 `tech.` tag 是查找式匹配），这些重复条目**对运行时零贡献**，纯粹污染效果列表。
2. **配方阶梯全量复制**：每个通用农业科技（机动农业/精准农业/自动化农业）都要挂 9 种作物的 method 建筑 × 11 种 good，一条科技 21 条效果，其中 20 条是模式复制。
3. **时代语义重复**：`机械化农业`(era6) → `机动农业`(era7) → `工业农学`(era8) → `精准农业`(era9) → `自动化农业`(era10)，五个时代连续"农业机械化"主题，但每个的"新知识"表达只有 r 等级 +1 的建筑名，没有新机制、新资源或新方法。

### 1.6 结构混乱 —— 连线与成本的双重失控

- `visual_edges` 1312 条（平均每节点 7.1 条）。polytech-tree 的红线是**每节点 prereqs+related 合计 ≤4 条**，超出就"塔上的连线糊成一片"。这里 alternative 边（635）甚至多于 hard 边（526）。
- **成本断崖**：帝国时代 min=42000 → 探索时代 min=3000（`方法：牧群路线议事帐`）。一个探索时代的科技比帝国时代最便宜的还便宜 14 倍，比农耕中位（9360）还便宜 3 倍。王国时代也有同类问题（`铜矿井开采` 3900 vs 农耕 max 12000）。
- **节点数-候选数错配**：见 1.4 第 4 点。

---

## 二、polytech-tree 可移植的策展方法论

polytech-tree 是一个 600+ 节点的人类科技树数据集 + 校验流水线，它的价值不在可视化（我们有自己的 static DAG UI），而在**五条数据策展规则**：

| polytech-tree 规则 | 原文要义 | 移植到 Project.Keynes |
|---|---|---|
| **重要度判据** | "抽掉它，后面有多少条科技站不住，而不是它出名不出名。同一时代同领域 1 档应当是少数" | 重新裁决 `anchor_kind`：当前 238 branch / 88 era_candidate / 32 backbone / 11 milestone，"era_candidate 占 24%"偏高；应为每个节点做"移除测试" |
| **prereqs ≤ 4** | "连线一多就糊成一片，只保留最能说明'为什么它必须存在'的那几条" | 拆掉 67 条长跳边：方法学关联→`research_routes`，产业链关联→`application_target_ids`；每节点 hard 前置收缩到 ≤4 |
| **era 由数据推导** | year 查 eras.json 区间，手填报错 | 断代矩阵应进入校验器：任何 branch_family 的时代空洞要么显式豁免（记录 terminal_reason），要么报错 |
| **core-ids.json 注册表** | 钉住核心科技的 era/category，防批量编辑挪错层 | 新增 `milestone_core_ids`：11 个里程碑 + 4 主干锚点的 era/domain/family 归属锁定，改动需在同一 PR 中显式声明 |
| **收录边界裁决** | 每批数据过"移除/保留/合并"裁决（如 review4：移 14 / 留 16 / 算 1） | 对 369 节点跑一轮收录裁决：合并同质节点（5 个"农业机械化"）、移除纯复制节点、补齐断代节点 |

---

## 三、优化方案（P0→P3，全部为 catalog/content 级改动，无需新 runtime）

> 按 runtime 契约：所有改动只动 `technology_network.json`（唯一 authoring source）、BuildingProfile/GoodProfile 资源的 tags 字段、以及 presentation 层。不新增 runtime 子系统、不动保存 schema 之外的东西。PKCN v11 存档对旧树返回 `catalog_hash_mismatch` 是预期行为。

### P0 · 止血修复（1-2 天，不改拓扑）

| # | 修复项 | 操作 | 状态标注 |
|---|---|---|---|
| P0-1 | 2 处信号复用 | `淡水岸捕`/`潮间带采集`：reveal 保留资源信号，route 改用 `SIGNAL_COUNT` 阈值或 `AT_LEAST` 复合（如捕捞实践次数），不再复用同一原子 | `catalog_rebind` |
| P0-2 | 4 条 successor 不一致 | `学术社团→科学分类` 等 4 组：二选一——补上对方前置，或删掉 branch_successor_ids 声明 | `catalog_rebind` |
| P0-3 | 成本断崖 | `牧群议事帐` 3000 → 对齐探索时代区间（≥30000）；`铜矿井开采` 3900 → 对齐王国区间（≥15000）。顺手加一条校验：节点 cost 不得低于前一时代中位数的 50% | `catalog_rebind` |
| P0-4 | 效果列表分层展示 | UI/展示层（`effect_summary` 生成逻辑）：`content_effects` 中建筑若 `required_technology_tags` 含未完成科技，折叠进"后续衍生"分组而非主列表。**只改 presentation，不动 content_effects 数据**（建筑的绑定关系本身是对的） | `existing_binding` |
| P0-5 | `industry.*` 清理 | C++ 侧 `compile_technology_tags` 已忽略非 `tech.` 前缀（`economy_runtime_catalog.cpp:654`），但 20 建筑 + 大量 good 里混着 `industry.food` 等。把 industry 标签迁到 `semantic_tags`，恢复 `technology_tags` 的单一语义 | `catalog_rebind` |

### P1 · 拓扑手术（核心，1-2 周）

**P1-1 拆长跳边（67 条）**——按语义分流：

- **方法学关联**（约 25 条，如 `工业农学 ← 早期玻璃烧制`）：移入 `research_routes[]` 的 `professional_knowledge` 路线条件。玻璃烧制作为"实验观察方法"的来源，写进 route explanation："通过玻璃器皿制作中积累的定量观察经验"。
- **产业链关联**（约 30 条，如 `先进冶金 ← 铜矿井开采`、`自动化农业 ← 深部开采`）：移入 `application_target_ids` 或直接删除——下游科技用到的原料，其获取科技已经通过建筑 required_technology_tags 生效，无需在研究前置里重复。
- **真正的核心知识**（约 12 条，如 `高地精准农业 ← 高地块茎农业` 跨 8 代）：插入 1-2 个中继节点补链。例：高地块茎农业 →（山地轮作，empire 时代新节点）→ 山地机械化 → 高地精准农业。**每个中继节点必须是真知识**（有独立效果绑定），不是纯桥接。

**P1-2 断代族裁决**——对 20 个断代族逐个过"三选一"：

- **补节点**（推荐 10 个族）：`food_storage` 主干补蒸汽-信息时代的罐头灭菌/冷冻运输/食品工业链（3-4 节点，绑定已有的 canned_fish good——它已存在但无科技解锁链）；`maize_horticulture` 补王国-蒸汽的杂交育种线；`commerce_finance` 补工业时代的银行/保险。
- **显式终止**（4 个族）：`tropical_commodities`、`tuber_highland` 等地区限定线，在最后一个节点填写 `terminal_reason`（"热带经济作物的工业化由 plantation 通用线接管，见 method_rubber_tree_collector_r8 的 required 链"），让 UI 明确告知玩家此线的去向。
- **合并**（3 个族）：`water_wind` 并入 `electric_intelligent_energy`（水力→水电的连续谱系）；`forest_biomass` 并入 `construction_materials` 或独立标记。

**P1-3 时代再平衡**：

- 后期每时代增加 4-6 个节点（含 P1-2 的补链节点），农业 domain 每时代至少 3 个（当前原子时代只有 1 个）。
- 21 个叶子节点处理：`畜力牵引`、`天文导航`、`工资契约` 等给后继（它们都有天然下文：畜力→马具/犁具深化，天文导航→经度测定）；确属终点的补 `terminal_reason`。
- 4 个零前置主干节点：`农耕社会` 至少加"种子选择"类前置，`王国体系` 加"记事制度"，恢复知识积累感。

**P1-4 视觉减负**：hard 边收缩后，`visual_edges` 目标从 1312 → ≤900；alternative 边只保留"跨路线的等价证据"（如物候观察 vs 洪水历法互为替代），同族内的 alternative 边删除（族内关系由 UI 折叠展示）。

### P2 · 语义修复（与 P1 并行）

| # | 修复项 | 操作 |
|---|---|---|
| P2-1 | **后期 reveal 多样化** | 100 个纯 `development.*` 的后期节点，至少 30 个改用真实信号：`卫星观测 ← 接触过他国地图（contact.*）`、`计算生物学 ← bio.* 物种观察计数`、`机器学习 ← 需先见过大规模数据（SIGNAL_COUNT 信号）`。目标：每个时代 reveal 构成中资源/生物/接触类 ≥25% |
| P2-2 | **good 重复条目清理** | `精准农业`/`自动化农业`/`机动农业` 等 7 个科技删除纯重复的 good unlock 条目（作物 access 已由前期科技授予），`effect_summary` 改写为"解锁 9 种作物的精准（r8）生产方式建筑"——一条聚合句替代 11 条重复项 |
| P2-3 | **method 系列语义化命名** | `method_rubber_tree_collector_r8` 的 `maturity_display_name` 已有"精准/数字化"，把 display_name 统一为"精准橡胶种植园"模式是对的，但"智能化电池厂/智能化电动机厂/智能化不锈钢厂"三连撞——建议按行业术语区分（智能电池产线/伺服电机厂/连铸不锈钢厂） |
| P2-4 | **19 个研究机构效果差异化** | 每个机构的 `modifier_terms` 已有（如 `country.research.agriculture_efficiency`），但 effect_summary 未展示差异。把这 19 个的摘要改写为突出各自加成方向（"学术社团：科学类研究效率 +X%"），删掉雷同的"解锁物资：科技点"表述 |
| P2-5 | **名字-效果对齐** | `算法治理` 的 `smart_water_network` 移到以水资源治理命名的科技下，或该建筑换绑 `tech.networked_computing`；`货币→珠宝厂`、`城市卫生→制皂厂` 的 required 链改用非地区限定原料（植物油/碱液而非"雨养玉米田"） |

### P3 · 流程固化（防退化，合入现有校验体系）

1. **新增 `audit_technology_topology.py`**（挂进 `verify_technology_runtime.ps1` 或 CI）：
   - 长跳检查：hard 前置时代跨度 >2 报警；
   - 断代检查：branch_family 时代空洞无 `terminal_reason` 豁免则报错；
   - 信号复用检查：reveal 与 route 共享原子则报错（现有 2 处修完后归零）；
   - 成本单调检查：`next_era.min_cost >= prev_era.median_cost * 0.5`；
   - 叶子检查：branch 叶子无 terminal_reason 且非时代末节点则警告；
   - good 重复解锁检查：同一 good 的 unlock 出现在 >3 个科技且无新配方建筑则警告。
2. **milestone core 注册表**：在 JSON 顶层新增 `core_ids`，钉住 11 里程碑 + 4 主干锚点的 `era_id/domain_id/branch_family_id`，编辑校验器对注册表条目做变更拦截（polytech-tree core-ids.json 模式）。
3. **收录裁决流程**：新科技入库前必须回答移除测试（"抽掉它，哪些科技站不住？"）并填写 `prerequisite_rationales`；批量调整跑"移除/保留/合并"三栏裁决，记录进 `semantic_review`。

---

## 四、实施顺序与依赖

```
P0（独立，随时可做，改完跑一次 verify_technology_runtime）
 └─→ P1-1 拆长跳 ──→ P1-4 视觉减负（依赖 P1-1 完成）
 └─→ P1-2/P1-3 断代补链（可并行，新节点需先过收录裁决 P3-3）
P2 全部可与 P1 并行（P2-2 依赖 P1-2 的配方建筑归属定案）
P3-1 校验器先行——先跑出当前全量报警清单，作为 P1/P2 的验收基线
```

**验收标准**（P1+P2 完成后）：
- hard 前置跨时代 >2 的边 = 0；每节点 hard 前置 ≤4
- 断代族全部有显式决策（补链或 terminal_reason）
- 后期（≥6）reveal 中资源/生物/地貌/接触信号占比 ≥25%
- 效果列表中"当前时代不可达"条目 = 0（展示层）
- 每时代节点数 25-40，农业 domain 每时代 ≥3
- `visual_edges` ≤900，alternative ≤ hard

---

## 五、本次审计未做的事（边界声明）

- 未改任何文件——这是纯诊断与方案，所有修改建议均标注了落地路径但未执行。
- `expected_bindings` 与 profession/consumption_plan 的完整交叉验证未做（building/good/resource 三向已做，profession 侧未做）。
- 369 节点的逐个"移除测试"裁决未做——这需要设计判断，本次只提供了数据支撑（断代矩阵、叶子清单、长跳清单）。
- `visual_edges` 削减的具体边清单未产出——依赖 P1-1 的分流结果。
